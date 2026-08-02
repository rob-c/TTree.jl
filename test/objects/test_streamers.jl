using TTree
using TTree.Bytes
using TTree.IOFS
using TTree.Objects

@testset "objects: streamer descriptions" begin
    @testset "the table covers what the package writes" begin
        # Writing a class without describing it produces a file ROOT can open
        # and not read, which is the worst possible outcome, so the table has to
        # be complete with respect to the registry.
        described = Set(describable_classes())
        exempt = Set([
            # Read only: these are the classes a file may contain that this
            # package decodes but never emits on its own.
            "TBasket",
        ])
        for cls in keys(Objects.class_registry())
            cls in exempt && continue
            @test cls in described
        end
    end

    @testset "descriptions are self-consistent" begin
        for cls in describable_classes()
            si = streamer_info(cls)
            @test si !== nothing
            @test Bytes.described_class(si) == cls
            @test Objects.elements(si) isa AbstractVector
            # Every element must name a type and a size, or the description
            # would not describe anything.
            for e in Objects.elements(si)
                el = Objects.element(e)
                @test !isempty(el.ename)
                @test el.esize >= 0
            end
        end
    end

    @testset "a description re-encodes to itself" begin
        for cls in describable_classes()
            si = streamer_info(cls)
            w = WBuffer()
            Bytes.marshal!(w, si)
            raw = bytes(w)

            back = TStreamerInfo()
            Bytes.unmarshal!(back, RBuffer(raw; factory=Objects.CLASS_FACTORY))
            v = WBuffer()
            Bytes.marshal!(v, back)
            @test bytes(v) == raw
        end
    end

    @testset "describe prints something" begin
        io = IOBuffer()
        describe(io, streamer_info("TNamed"))
        s = String(take!(io))
        @test occursin("TNamed", s)
        @test occursin("fName", s)
    end

    @testset "a written file describes what it holds" begin
        # The StreamerInfo record is written from the same table, so a file this
        # package produces must come back naming the classes it contains.
        path = tempname() * ".root"
        TTree.create(path) do f
            f["s"] = TObjString("described")
            l = TList("l")
            push!(l, TNamed("n", "t"))
            f["l"] = l
        end
        TTree.open(path) do f
            db = streamers(f)
            got = Set(Bytes.described_class(si) for si in db.order)
            for cls in ("TObjString", "TObject", "TString", "TList", "TNamed")
                @test cls in got
            end
        end
        rm(path; force=true)
    end
end
