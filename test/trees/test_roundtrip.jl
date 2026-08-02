using TTree
using TTree.Bytes
using TTree.IOFS
using TTree.Objects
using TTree.Trees

@testset "trees: round-trip" begin
    # Every tree in the corpus, written back out with this package's own
    # streamer and read again. Reading is checked against ROOT elsewhere; this
    # is what checks the writing, since a tree that survives the trip with its
    # branches, its leaves and its values intact was described correctly on the
    # way out.
    for r in reference("corpus_structure.txt")
        fn, tn = r[1], r[2]
        @testset "$fn/$tn" begin
            TTree.open(joinpath(corpus_dir(), fn)) do f
                t = f[tn]
                cls = Bytes.classname(t)

                w = WBuffer()
                Bytes.marshal!(w, t)
                back = Objects.CLASS_FACTORY(cls)
                Bytes.unmarshal!(back, RBuffer(bytes(w); factory=Objects.CLASS_FACTORY))
                # The baskets still on the file are reached through it, so the
                # copy has to be told where it came from.
                Bytes.bind!(back, f)

                @test Objects.name(back) == Objects.name(t)
                @test entries(back) == entries(t)

                was = allbranches(t)
                now = allbranches(back)
                @test length(now) == length(was)
                @test [Objects.name(b) for b in now] == [Objects.name(b) for b in was]

                for (b1, b2) in zip(was, now)
                    ls = leaves(b1)
                    @test [Objects.name(l) for l in leaves(b2)] == [Objects.name(l) for l in ls]
                    for l in ls
                        l isa Union{TLeafElement,TLeafObject} && continue
                        nm = Objects.name(l)
                        @test array(b2, nm) == array(b1, nm)
                    end
                end
            end
        end
    end
end
