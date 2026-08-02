using TTree.Bytes
using TTree.Objects

# Encode an object and read it back into a fresh instance of the same class,
# through the registry rather than by naming the type — which is the path a
# file takes.
function reencode(obj)
    w = WBuffer()
    Bytes.marshal!(w, obj)
    raw = bytes(w)
    back = Objects.CLASS_FACTORY(Bytes.classname(obj))
    r = RBuffer(raw; factory=Objects.CLASS_FACTORY)
    Bytes.unmarshal!(back, r)
    @test remaining(r) == 0
    return back
end

@testset "objects: classes" begin
    @testset "every class is constructible by name" begin
        for (cls, _) in Objects.class_registry()
            @test Objects.CLASS_FACTORY(cls) !== nothing
        end
        @test Objects.CLASS_FACTORY("NoSuchClass") === nothing
    end

    @testset "TObject and TNamed" begin
        # `kIsOnHeap` and `kNotDeleted` say how C++ owns an object, not anything
        # about the file, so ROOT masks both out on the way down and sets
        # `kIsOnHeap` again on the way up. A round-trip is therefore expected to
        # lose `kNotDeleted` — matching ROOT is the point, not fixed-pointness.
        o = reencode(TObject())
        @test o.id == 0
        @test o.bits == UInt32(Bytes.KIS_ON_HEAP)

        n = reencode(TNamed("thing", "a title"))
        @test Objects.name(n) == "thing"
        @test Objects.title(n) == "a title"

        s = reencode(TObjString("hello"))
        @test s.str == "hello"
        @test String(s) == "hello"
        @test Objects.name(s) == "hello"

        # A TString spans the one-byte length boundary the same way inside an
        # object as it does on its own.
        @test reencode(TObjString("x"^300)).str == "x"^300
        @test reencode(TObjString("")).str == ""
    end

    @testset "attributes" begin
        for a in (TAttLine(), TAttFill(), TAttMarker(), TAttAxis())
            b = reencode(a)
            @test typeof(b) === typeof(a)
        end
        a = TAttLine()
        a.color = Int16(4)
        a.width = Int16(3)
        b = reencode(a)
        @test b.color == 4 && b.width == 3
    end

    @testset "lists" begin
        l = TList("mylist")
        push!(l, TObjString("one"))
        push!(l, TObjString("two"), "opt")
        push!(l, nothing)
        b = reencode(l)
        @test Objects.name(b) == "mylist"
        @test length(b) == 3
        @test b[1].str == "one"
        @test b[3] === nothing
        @test options(b) == ["", "opt", ""]

        h = THashList("hashed", Any[TObjString("a")])
        @test reencode(h)[1].str == "a"

        # An object appearing twice is written once and referenced the second
        # time, and must still be one object when it comes back.
        shared = TObjString("shared")
        l2 = TList("shared-list")
        push!(l2, shared)
        push!(l2, shared)
        b2 = reencode(l2)
        @test b2[1] === b2[2]
        @test b2[1].str == "shared"
    end

    @testset "object arrays" begin
        a = TObjArray("myarray", Any[TObjString("a"), nothing, TObjString("c")])
        b = reencode(a)
        @test Objects.name(b) == "myarray"
        @test length(b) == 3
        @test b[1].str == "a"
        @test b[2] === nothing
        @test b[3].str == "c"

        @test length(reencode(TObjArray())) == 0
    end

    @testset "numeric arrays" begin
        for (cls, v) in (
            TArrayC => Int8[-1, 0, 7],
            TArrayS => Int16[-300, 300],
            TArrayI => Int32[-70_000, 1],
            TArrayL => Int64[-(1 << 40)],
            TArrayL64 => Int64[1 << 40],
            TArrayF => Float32[1.5, -2.5],
            TArrayD => Float64[1e300, -0.5],
        )
            a = cls(v)
            b = reencode(a)
            @test typeof(b) === cls
            @test collect(b) == v
            @test length(b) == length(v)
        end

        @test length(TArrayI(5)) == 5
        @test all(iszero, TArrayI(5))
        @test collect(reencode(TArrayD())) == Float64[]
    end
end
