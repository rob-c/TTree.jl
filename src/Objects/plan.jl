# Turning a file's description of a class into a plan for reading it.
#
# The description is the `TStreamerInfo` list the writing program stored — the
# same one ROOT reads the file back with — and it is authoritative: a member
# added, widened or renamed since is described as the file has it, not as the
# class is today. So this reads what is there and nothing else.
#
# Two things the description does not say have to be supplied from elsewhere.
# A container's element type is in its type name and nowhere else, which is
# what `typename.jl` is for. And a handful of classes ROOT streams by hand —
# `TObject`, `TDatime`, `TString` — do not write what their description says
# they do; those are recognised by name, because nothing in the file
# distinguishes them.

"""
    PlanContext

What building a plan needs to hand down: the file's streamer database, and the
classes already being built, so that a class holding itself is caught rather
than followed forever.
"""
struct PlanContext
    db::Any
    seen::Set{String}
end

PlanContext(db) = PlanContext(db, Set{String}())

"""
    class_plan(db, class, version=-1) -> ValuePlan

A plan for reading one object of `class`, from `db`'s description of it.

`db` is a file's [`StreamerDB`](@ref TTree.IOFS.StreamerDB), or `nothing` to
fall back on the classes this package describes itself. A class nothing
describes gives an [`OpaquePlan`](@ref) rather than an error: it can still be
stepped over wherever it was written with a byte count, which is how a file
full of experiment-specific classes stays readable.
"""
function class_plan(db, class::AbstractString, version::Integer=-1)
    return context_plan(PlanContext(db), String(class), Int(version))
end

"""
    context_plan(ctx, class, version) -> ValuePlan

[`class_plan`](@ref) once the context exists — the form the members of a class
recurse through, and the only one that may be called with a context in hand.
"""
function context_plan(ctx::PlanContext, class::String, version::Int)
    p = builtin_plan(class)
    p === nothing || return p
    class in ctx.seen && return OpaquePlan(class, "it is defined in terms of itself")
    si = ctx.db === nothing ? nothing : Bytes.streamer_info(ctx.db, class, version)
    si === nothing && (si = streamer_info(class))
    si === nothing && return OpaquePlan(class, "nothing in the file describes it")

    push!(ctx.seen, class)
    els = elements(si)
    byname = Dict{String,Int}()
    for (i, e) in enumerate(els)
        byname[String(name(e))] = i
    end
    members = MemberPlan[member_plan(ctx, e, byname) for e in els]
    delete!(ctx.seen, class)
    return ObjectPlan(class, members)
end

"""
    builtin_plan(class) -> Union{ValuePlan,Nothing}

The plan for a class ROOT streams by hand, or `nothing` for one it streams from
its description.

These are the classes whose bytes are not what their streamer info says: a
`TDatime` is four bytes with no header at all, a `TObject` a bare version word
and two integers, a `TString` its own length and content. A reader that went by
the description alone would misread every one of them.
"""
function builtin_plan(class::AbstractString)
    class == "TObject" && return TObjectPlan()
    class == "TDatime" && return DatimePlan()
    (class == "TString" || class == "string") && return StringPlan()
    return nothing
end

"""
    type_plan(db, t::CppType) -> ValuePlan

A plan for a type named rather than described — a container's element type, or
the container itself.
"""
type_plan(db, t::CppType) = type_plan(PlanContext(db), t)

function type_plan(ctx::PlanContext, t::CppType)
    T = cpp_scalar(t.name)
    T === nothing || return ScalarPlan(T)
    t.name == "Double32_t" && return PackedPlan{Float64}(0.0, 0.0, 0.0)
    t.name == "Float16_t" && return PackedPlan{Float32}(0.0, 0.0, 0.0)
    t.name == "string" && return StringPlan()
    if t.name == "bitset"
        n = length(t.args) == 1 ? something(tryparse(Int, t.args[1].name), 0) : 0
        return BitsetPlan(cppname(t), n)
    end
    is_sequence(t) && return SequencePlan(cppname(t), type_plan(ctx, t.args[1]))
    is_map(t) && return SequencePlan(cppname(t), pair_plan(ctx, t))
    return context_plan(ctx, cppname(t), -1)
end

"""
    pair_plan(ctx, t::CppType) -> ValuePlan

A plan for the `pair<K,V>` a map holds.

ROOT usually writes the pair's streamer info into the file, and that is
preferred — it settles the framing of each half the same way it is settled for
any other class. A file that leaves it out is read from the type name instead,
which says as much.
"""
function pair_plan(ctx::PlanContext, t::CppType)
    cls = cppname(CppType("pair", CppType[t.args[1], t.args[2]]))
    if ctx.db !== nothing && Bytes.streamer_info(ctx.db, cls, -1) !== nothing
        p = context_plan(ctx, cls, -1)
        p isa ObjectPlan && length(p.members) == 2 && return p
    end
    return ObjectPlan(
        cls,
        MemberPlan[
            element_member(ctx, :first, t.args[1]), element_member(ctx, :second, t.args[2])
        ],
    )
end

"""
    element_member(ctx, name, t::CppType) -> MemberPlan

One half of a pair, framed as ROOT frames it: a container or a `std::string`
carries a header of its own, a number or a `TString` does not.
"""
function element_member(ctx::PlanContext, nm::Symbol, t::CppType)
    p = type_plan(ctx, t)
    framed = t.name == "string" || is_sequence(t) || is_map(t) || t.name == "bitset"
    framed |= p isa ObjectPlan
    return MemberPlan(nm, cppname(t), p, framed)
end

"""
    nested_framing(plan) -> Bool

Whether a value of `plan` written inside a class carries a header of its own.

Almost everything nested does; the exceptions are the classes that stream
themselves, which write their own version word or nothing at all and would be
read twice over if a header were expected as well.
"""
nested_framing(::ValuePlan) = true
nested_framing(::TObjectPlan) = false
nested_framing(::DatimePlan) = false
nested_framing(::ScalarPlan) = false
nested_framing(::PackedPlan) = false

"""
    member_plan(ctx, e, byname) -> MemberPlan

A plan for one element of a streamer info: a data member, or a base class.

`byname` maps the class's member names to their positions, which is how a
variable-length member finds the member that counts it.
"""
function member_plan(ctx::PlanContext, e, byname::Dict{String,Int})
    nm = Symbol(name(e))
    t = Int(etype(e))

    if e isa TStreamerBase
        # The element's *name* is the base class; its type name is "BASE".
        cls = String(name(e))
        p = context_plan(ctx, cls, Int(e.vbase))
        return MemberPlan(nm, cls, p, nested_framing(p))
    end

    if e isa TStreamerSTLstring
        return MemberPlan(nm, "string", StringPlan(), true)
    end

    if e isa TStreamerSTL
        cls = String(typename(e))
        return MemberPlan(nm, cls, type_plan(ctx, parse_typename(cls)), true)
    end

    t == RMETA_TSTRING && return MemberPlan(nm, "TString", StringPlan(), false)
    t == RMETA_CHARSTAR && return MemberPlan(nm, "", CharStarPlan(), false)

    if t in
        (RMETA_OBJECT, RMETA_ANY, RMETA_OBJECTP, RMETA_ANYP, RMETA_TOBJECT, RMETA_TNAMED)
        cls = String(typename(e))
        p = context_plan(ctx, cls, -1)
        return MemberPlan(nm, cls, p, nested_framing(p))
    end

    if t in (RMETA_OBJECT_P, RMETA_ANY_P, RMETA_ANY_P_NO_VT)
        cls = String(typename(e))
        return MemberPlan(nm, cls, PointerPlan(cls), false)
    end

    if RMETA_OFFSET_P < t < RMETA_OFFSET_P + RMETA_OFFSET_L
        el = scalar_plan(e)
        el === nothing && return opaque_member(nm, e, "its element type is not a number")
        cnt = e isa TStreamerBasicPointer ? String(e.cname) : ""
        idx = get(byname, cnt, 0)
        idx == 0 && return opaque_member(
            nm, e, "the member $(repr(cnt)) that counts it is not in this class"
        )
        per = max(Int(arraylen(e)), 1)
        return MemberPlan(nm, "", CountedPlan(el, idx, per), false)
    end

    if RMETA_OFFSET_L < t < RMETA_OFFSET_P
        el = scalar_plan(e)
        el === nothing && return opaque_member(nm, e, "its element type is not a number")
        return MemberPlan(nm, "", FixedPlan(el, array_dims(e)), false)
    end

    p = scalar_plan(e)
    p === nothing &&
        return opaque_member(nm, e, "streamer type $t is not one this package reads")
    return MemberPlan(nm, "", p, false)
end

"""
    opaque_member(name, e, why) -> MemberPlan

A member left undecoded but still stepped over, on the chance that it was
written with a byte count. See [`OpaquePlan`](@ref).
"""
function opaque_member(nm::Symbol, e, why::AbstractString)
    return MemberPlan(nm, String(typename(e)), OpaquePlan(String(typename(e)), why), true)
end

"""
    scalar_plan(e) -> Union{ValuePlan,Nothing}

The number one value of element `e` holds, at the width and packing its
description gives it, or `nothing` if it does not hold a number.
"""
function scalar_plan(e)
    t = base_type(etype(e))
    el = element(e)
    t == RMETA_DOUBLE32 && return PackedPlan{Float64}(el.xmin, el.xmax, el.factor)
    t == RMETA_FLOAT16 && return PackedPlan{Float32}(el.xmin, el.xmax, el.factor)
    T = julia_type(t)
    T === nothing && return nothing
    return ScalarPlan(T)
end

"""
    array_dims(e) -> Vector{Int}

The dimensions of a fixed-size member, `[3]` or `[2, 4]`.

A file written by ROOT 3 gives only the total, which is the same thing for the
one-dimensional members that were all it could describe.
"""
function array_dims(e)
    dims = Int[Int(d) for d in arraydims(e) if d > 0]
    isempty(dims) && return Int[max(Int(arraylen(e)), 1)]
    return dims
end
