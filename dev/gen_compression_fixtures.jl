# Regenerate `test/data/compressed/*.root` — one small file per compression
# algorithm ROOT can write.
#
# The corpus this package is otherwise tested against is zlib throughout, which
# leaves the LZ4, LZMA and Zstandard block readers — and the xxHash64 that
# guards an LZ4 block — with nothing to check them. These are ROOT's own output,
# so they are the answer to "would ROOT have written it this way"; they are a
# few kilobytes each, so unlike the corpus they can simply be checked in.
#
# Usage, from the package root:
#
#     julia --project=. dev/gen_compression_fixtures.jl
#
# Requires a `root` on PATH. The contents must stay in step with
# `test/compress/test_blocks.jl`, which knows what is in them.

const DATA = normpath(joinpath(@__DIR__, "..", "test", "data", "compressed"))

# ROOT's algorithm numbering, as `Compress` spells it.
const ALGORITHMS = [("zlib", 1), ("lzma", 2), ("lz4", 4), ("zstd", 5)]

# Enough entries that the payload is well past the 512 bytes below which ROOT
# does not compress at all, and regular enough that it actually shrinks.
const MACRO = raw"""
void gen() {
  const char *dir = "@DIR@";
  const char *name = "@NAME@";
  int alg = @ALG@;

  TFile f(TString::Format("%s/%s.root", dir, name), "recreate");
  f.SetCompressionAlgorithm((ROOT::RCompressionSetting::EAlgorithm::EValues)alg);
  f.SetCompressionLevel(5);

  TTree t("t", "compression fixture");
  Int_t i;
  Float_t x;
  Double_t d;
  t.Branch("i", &i, "i/I");
  t.Branch("x", &x, "x/F");
  t.Branch("d", &d, "d/D");
  for (int e = 0; e < 2000; ++e) {
    i = e;
    x = e * 0.5f;
    d = e * 0.25;
    t.Fill();
  }
  t.Write();
  f.Close();

  TFile g(TString::Format("%s/%s.root", dir, name));
  printf("WROTE\t%s\t%d\t%lld\n", name, g.GetCompressionAlgorithm(),
         (long long)((TTree *)g.Get("t"))->GetEntries());
  g.Close();
}
"""

function main()
    mkpath(DATA)
    mktempdir() do tmp
        for (name, alg) in ALGORITHMS
            path = joinpath(tmp, "gen.C")
            write(
                path,
                replace(MACRO, "@DIR@" => DATA, "@NAME@" => name, "@ALG@" => string(alg)),
            )
            out = read(`root -l -b -q $path`, String)
            m = match(r"WROTE\t(\S+)\t(\d+)\t(\d+)", out)
            m === nothing && error("ROOT did not write $name:\n$out")
            parse(Int, m.captures[2]) == alg ||
                error("$name: ROOT stored algorithm $(m.captures[2]), asked for $alg")
            println(
                rpad(name, 6),
                " alg=",
                alg,
                " entries=",
                m.captures[3],
                "  ",
                filesize(joinpath(DATA, name * ".root")),
                " bytes",
            )
        end
    end
    return 0
end

exit(main())
