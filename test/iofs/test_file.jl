using TTree
using TTree.Bytes
using TTree.Compress
using TTree.IOFS
using TTree.Objects

@testset "iofs: files" begin
    @testset "write and read back" begin
        path = tempname() * ".root"
        payload = UInt8[(i * 31 + 7) % 256 for i in 1:4096]
        small = collect(codeunits("hello root"))

        f = TTree.create(path)
        put_key!(f, f.dir, "big", "a big object", "TObjString", payload)
        put_key!(f, f.dir, "small", "a small one", "TObjString", small)
        put_key!(f, f.dir, "small", "a second cycle", "TObjString", small)
        close(f)

        g = TTree.open(path)
        try
            @test keys(g) == ["big", "small"]
            @test key_payload(g.source, findkey(g.dir, "big")) == payload
            @test key_payload(g.source, findkey(g.dir, "small")) == small

            # Rewriting a name does not replace it: the older copy is still
            # there under its own cycle, and the bare name means the newest.
            @test findkey(g.dir, "small").cycle == 2
            @test findkey(g.dir, "small").title == "a second cycle"
            @test findkey(g.dir, "small;1").title == "a small one"
            @test findkey(g.dir, "small;3") === nothing
            @test findkey(g.dir, "absent") === nothing

            # The header's idea of where the file ends must be the file's.
            @test g.fend == filesize(path)
            @test g.version >= IOFS.ROOT_VERSION || g.version > 1000
            @test free_tail(g.spans) !== nothing
        finally
            close(g)
        end
        rm(path; force=true)
    end

    @testset "objects" begin
        path = tempname() * ".root"
        TTree.create(path) do f
            f["greeting"] = TObjString("hello from Julia")
            f["greeting"] = TObjString("second cycle")
            write!(f, "explicit", TObjString("with a title"); title="a custom title")

            l = TList("mylist")
            push!(l, TObjString("one"))
            push!(l, TObjString("two"), "draw-option")
            push!(l, TNamed("named", "a title"))
            f["list"] = l

            f["array"] = TObjArray(
                "myarray", Any[TObjString("a"), nothing, TObjString("c")]
            )
        end

        TTree.open(path) do f
            @test sort(keys(f)) == ["array", "explicit", "greeting", "list"]
            @test f["greeting"].str == "second cycle"
            @test f["greeting;1"].str == "hello from Julia"
            @test findkey(f.dir, "explicit").title == "a custom title"

            l = f["list"]
            @test l isa TList
            @test Objects.name(l) == "mylist"
            @test length(l) == 3
            @test [o isa TObjString ? o.str : Objects.name(o) for o in l] == ["one", "two", "named"]
            @test options(l) == ["", "draw-option", ""]

            a = f["array"]
            @test a isa TObjArray
            @test length(a) == 3
            @test collect(a)[2] === nothing
            @test collect(a)[3].str == "c"
        end
        rm(path; force=true)
    end

    @testset "compression settings are honoured" begin
        # Big enough to be worth compressing, and repetitive enough that it is.
        payload = repeat(collect(codeunits("compress me please ")), 300)
        for alg in
            (Compress.ALG_ZLIB, Compress.ALG_LZ4, Compress.ALG_ZSTD, Compress.ALG_LZMA)
            path = tempname() * ".root"
            TTree.create(path; compression=Settings(alg, 5)) do f
                put_key!(f, f.dir, "p", "", "TObjString", payload)
            end
            TTree.open(path) do f
                @test settings_from(f.compression) == Settings(alg, 5)
                k = findkey(f.dir, "p")
                @test is_compressed(k)
                @test k.objlen == length(payload)
                @test key_payload(f.source, k) == payload
            end
            rm(path; force=true)
        end
    end

    @testset "sources" begin
        path = tempname() * ".root"
        TTree.create(path) do f
            f["s"] = TObjString("from a source")
        end
        raw = read(path)

        # The same file reached four ways must decode identically; this is what
        # keeps the byte layer free of any assumption about where bytes live.
        for target in (path, raw, IOBuffer(raw))
            TTree.open(target) do f
                @test f["s"].str == "from a source"
            end
        end
        rm(path; force=true)
    end

    @testset "a file that is not one" begin
        path = tempname() * ".root"
        write(path, "not a ROOT file at all, not even close")
        @test_throws Exception TTree.open(path)
        rm(path; force=true)
    end
end
