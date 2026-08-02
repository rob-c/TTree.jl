# Regenerate `test/data/trees/trees.root` — one small tree holding every leaf
# shape this package decodes, written into several baskets.
#
# The corpus covers far more of the format than this does, but it is not
# shipped with the package, so without this file a machine with no corpus tests
# no tree reading at all. What it adds beyond coverage is baskets: no branch in
# the corpus splits its entries across more than one, and a branch that fits in
# a single basket cannot tell a reader that stops after the first from one that
# does not. Here the basket size is set small enough that every branch spans
# several.
#
# Usage, from the package root:
#
#     julia --project=. dev/gen_tree_fixtures.jl
#
# Requires a `root` on PATH. The fills are a rule rather than a table — entry
# `i` holds `i`, `i/2`, `i % 4` values — so `test/trees/test_fixture.jl` states
# what it expects instead of transcribing it.

const DATA = normpath(joinpath(@__DIR__, "..", "test", "data", "trees"))

const NENTRIES = 100

const MACRO = raw"""
// A leaf-list branch takes one address and lays its leaves out packed from
// there, so the members have to be declared widest first — with `Int_t` first
// the compiler would pad to align the `Double_t` and every value of `b` would
// be written from the padding instead.
struct Pair {
  Double_t b;
  Int_t a;
};

void gen() {
  TFile f("@DIR@/trees.root", "recreate", "", 101);  // zlib, level 1
  TTree t("t", "every leaf shape");

  Int_t i32;
  UInt_t u32;
  Long64_t i64;
  Float_t f32;
  Double_t f64;
  Bool_t bo;
  Double_t arr[3];
  Int_t n;
  Double_t sli[8];
  Char_t str[16];
  Pair pair;

  t.Branch("i32", &i32, "i32/I");
  t.Branch("u32", &u32, "u32/i");
  t.Branch("i64", &i64, "i64/L");
  t.Branch("f32", &f32, "f32/F");
  t.Branch("f64", &f64, "f64/D");
  t.Branch("bo", &bo, "bo/O");
  t.Branch("arr", arr, "arr[3]/D");
  // The count is a branch of its own, which is the usual arrangement and the
  // one that makes reading `sli` mean reading two columns.
  t.Branch("n", &n, "n/I");
  t.Branch("sli", sli, "sli[n]/D");
  t.Branch("str", str, "str/C");
  // Two leaves in one branch: they are stored interleaved, so reading `a`
  // means stepping over `b` in every entry.
  t.Branch("pair", &pair, "b/D:a/I");

  // Small enough that @N@ entries do not fit in one basket. ROOT rounds this
  // up to its own minimum, which is still far below the size of a branch.
  t.SetBasketSize("*", 256);

  for (Int_t e = 0; e < @N@; ++e) {
    i32 = e;
    u32 = 4000000000u + e;
    i64 = 5000000000LL * (e + 1);
    f32 = e + 0.5f;
    f64 = e / 2.0;
    bo = (e % 3 == 0);
    for (int k = 0; k < 3; ++k) arr[k] = e + k / 10.0;
    n = e % 4;
    for (int k = 0; k < n; ++k) sli[k] = 100 * e + k;
    snprintf(str, sizeof(str), "e%d", e);
    pair.a = -e;
    pair.b = e * 1.5;
    t.Fill();
  }

  t.Write();
  f.Close();

  // Read it back and say what ROOT itself sees. The basket counts are the
  // reason this file exists, so they are what is printed.
  TFile g("@DIR@/trees.root");
  printf("ROOTVERSION\t%s\n", gROOT->GetVersion());
  TTree *r = (TTree *)g.Get("t");
  printf("TREE\t%s\t%lld\n", r->GetName(), r->GetEntries());
  TIter next(r->GetListOfBranches());
  while (TBranch *b = (TBranch *)next()) {
    printf("BRANCH\t%s\t%d\t%d\n", b->GetName(), b->GetWriteBasket(),
           b->GetNleaves());
  }
  g.Close();
}
"""

function main()
    mkpath(DATA)
    mktempdir() do tmp
        path = joinpath(tmp, "gen.C")
        write(path, replace(MACRO, "@DIR@" => DATA, "@N@" => string(NENTRIES)))
        out = read(`root -l -b -q $path`, String)
        occursin("BRANCH\t", out) || error("ROOT did not write the fixture:\n$out")
        print(out)
        file = joinpath(DATA, "trees.root")
        return println("wrote ", file, " (", filesize(file), " bytes)")
    end
    return 0
end

exit(main())
