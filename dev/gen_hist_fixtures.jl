# Regenerate `test/data/hists/hists.root` — one small file holding every
# histogram and graph class this package can read.
#
# The corpus is where the *old* layouts are checked: it has TAxis 6 and TH1 3
# in it, which no ROOT built this decade would write. What it does not have is
# a TH3, a labelled axis, or a histogram whose bin contents are known in
# advance — so this file supplies those, and being ROOT's own output it is the
# answer to "would ROOT have written it this way".
#
# Usage, from the package root:
#
#     julia --project=. dev/gen_hist_fixtures.jl
#
# Requires a `root` on PATH. The contents must stay in step with
# `test/objects/test_hist.jl` and `test/objects/test_graph.jl`, which know what
# is in them. The fills are deliberately regular — bin `i` gets `i` entries, a
# 2-D bin gets `100x + y` — so the tests can state what they expect rather than
# transcribe numbers out of this script's output.

const DATA = normpath(joinpath(@__DIR__, "..", "test", "data", "hists"))

const MACRO = raw"""
void gen() {
  TFile f("@DIR@/hists.root", "recreate");

  // A plain 1-D histogram, filled so that bin i holds i entries, plus one
  // underflow and two overflows: enough to tell a cell array that starts at
  // the underflow from one that starts at the first bin.
  TH1F h1f("h1f", "fixed bins", 10, 0, 10);
  for (int i = 1; i <= 10; ++i)
    for (int n = 0; n < i; ++n) h1f.Fill(i - 0.5);
  h1f.Fill(-1.0);
  h1f.Fill(10.5);
  h1f.Fill(11.5);
  h1f.Write();

  // Weighted, with the sum of squares of weights kept, so that the errors are
  // not simply the square root of the contents.
  TH1D h1d("h1d", "weighted", 10, 0, 10);
  h1d.Sumw2();
  for (int i = 1; i <= 10; ++i) h1d.Fill(i - 0.5, 2.0);
  h1d.Write();

  TH1I h1i("h1i", "integer bins", 5, 0, 5);
  for (int i = 1; i <= 5; ++i) h1i.SetBinContent(i, i * 1000);
  h1i.Write();

  // A `ClassDef(TH1L, 0)` class: its version is written as a checksum rather
  // than a number, and its contents do not fit in an Int32.
  TH1L h1l("h1l", "long bins", 4, 0, 4);
  for (int i = 1; i <= 4; ++i) h1l.SetBinContent(i, 5000000000LL * i);
  h1l.Write();

  // Variable-width bins: fXbins is filled, so the edges come from the array
  // rather than from fXmin and fXmax.
  const Double_t edges[5] = {0.0, 1.0, 3.0, 6.0, 10.0};
  TH1D hvar("hvar", "variable bins", 4, edges);
  for (int i = 1; i <= 4; ++i) hvar.SetBinContent(i, i);
  hvar.Write();

  // An alphanumeric axis: fLabels is a THashList of TObjString, which is the
  // one axis member that is an object rather than a number.
  TH1F hlab("hlab", "labelled", 3, 0, 3);
  hlab.Fill("alpha", 1.0);
  hlab.Fill("beta", 2.0);
  hlab.Fill("gamma", 3.0);
  hlab.Write();

  // 2-D and 3-D, with contents that say where they came from: x fastest, so a
  // reader that transposes the cell array gets 100*y + x and fails loudly.
  TH2F h2f("h2f", "2d", 3, 0, 3, 4, 0, 4);
  for (int ix = 1; ix <= 3; ++ix)
    for (int iy = 1; iy <= 4; ++iy) h2f.SetBinContent(ix, iy, 100 * ix + iy);
  h2f.Write();

  TH2D h2d("h2d", "2d filled", 3, 0, 3, 4, 0, 4);
  for (int ix = 1; ix <= 3; ++ix)
    for (int iy = 1; iy <= 4; ++iy) h2d.Fill(ix - 0.5, iy - 0.5);
  h2d.Write();

  TH3D h3d("h3d", "3d", 2, 0, 2, 3, 0, 3, 4, 0, 4);
  for (int ix = 1; ix <= 2; ++ix)
    for (int iy = 1; iy <= 3; ++iy)
      for (int iz = 1; iz <= 4; ++iz)
        h3d.SetBinContent(ix, iy, iz, 10000 * ix + 100 * iy + iz);
  h3d.Write();

  // A profile keeps the mean of y in each x bin, so its contents are not the
  // number of entries in the bin: bin i holds i and was filled twice.
  TProfile prof("prof", "profile", 4, 0, 4);
  for (int i = 1; i <= 4; ++i) {
    prof.Fill(i - 0.5, i - 1.0);
    prof.Fill(i - 0.5, i + 1.0);
  }
  prof.Write();

  TProfile2D prof2("prof2", "profile 2d", 2, 0, 2, 3, 0, 3);
  for (int ix = 1; ix <= 2; ++ix)
    for (int iy = 1; iy <= 3; ++iy) {
      prof2.Fill(ix - 0.5, iy - 0.5, 10 * ix + iy - 1);
      prof2.Fill(ix - 0.5, iy - 0.5, 10 * ix + iy + 1);
    }
  prof2.Write();

  // The graphs: y = 2x on four points, with errors that differ from one side
  // to the other so that an asymmetric pair cannot be read as a symmetric one.
  const Int_t np = 4;
  Double_t x[np] = {1, 2, 3, 4};
  Double_t y[np] = {2, 4, 6, 8};
  Double_t ex[np] = {0.1, 0.2, 0.3, 0.4};
  Double_t ey[np] = {0.5, 0.6, 0.7, 0.8};
  Double_t exl[np] = {0.01, 0.02, 0.03, 0.04};
  Double_t exh[np] = {0.11, 0.12, 0.13, 0.14};
  Double_t eyl[np] = {0.21, 0.22, 0.23, 0.24};
  Double_t eyh[np] = {0.31, 0.32, 0.33, 0.34};

  TGraph tg(np, x, y);
  tg.SetName("tg");
  tg.SetTitle("plain");
  tg.Write();

  TGraphErrors tge(np, x, y, ex, ey);
  tge.SetName("tge");
  tge.SetTitle("symmetric errors");
  tge.Write();

  TGraphAsymmErrors tgae(np, x, y, exl, exh, eyl, eyh);
  tgae.SetName("tgae");
  tgae.SetTitle("asymmetric errors");
  tgae.Write();

  f.Close();

  // Read it back and say what ROOT itself sees, so that a change in ROOT that
  // moves any of these numbers shows up here rather than as a failing test.
  TFile g("@DIR@/hists.root");
  printf("ROOTVERSION\t%s\n", gROOT->GetVersion());
  TIter next(g.GetListOfKeys());
  while (TKey *k = (TKey *)next()) {
    TObject *o = k->ReadObj();
    if (o->InheritsFrom(TH1::Class())) {
      TH1 *h = (TH1 *)o;
      printf("HIST\t%s\t%s\t%g\t%g\t%d\t%g\t%g\n", k->GetClassName(), h->GetName(),
             h->GetEntries(), h->GetSumOfWeights(), h->GetNcells(),
             h->GetBinContent(1), h->GetBinError(1));
    } else if (o->InheritsFrom(TGraph::Class())) {
      TGraph *t = (TGraph *)o;
      printf("GRAPH\t%s\t%s\t%d\t%g\t%g\n", k->GetClassName(), t->GetName(),
             t->GetN(), t->GetPointX(0), t->GetPointY(0));
    }
  }
  g.Close();
}
"""

function main()
    mkpath(DATA)
    mktempdir() do tmp
        path = joinpath(tmp, "gen.C")
        write(path, replace(MACRO, "@DIR@" => DATA))
        out = read(`root -l -b -q $path`, String)
        occursin("HIST\t", out) || error("ROOT did not write the fixtures:\n$out")
        print(out)
        return println(
            "wrote ",
            joinpath(DATA, "hists.root"),
            " (",
            filesize(joinpath(DATA, "hists.root")),
            " bytes)",
        )
    end
    return 0
end

exit(main())
