# Regenerate `test/data/corpus_structure.txt`, `test/data/corpus_leaves.txt` and
# `test/data/corpus_hists.txt` — what ROOT says about every tree, and every
# histogram and graph, in the test corpus.
#
# The tree tests compare against ROOT rather than against a previous run of this
# package, which is the only comparison worth making; but ROOT is not something
# a test suite can assume is installed. So ROOT's answers are recorded here,
# once, and checked in.
#
# Usage, from the package root:
#
#     julia --project=. dev/gen_corpus_reference.jl [corpus-dir]
#
# Requires a `root` on PATH. The corpus directory defaults to `TTREE_TESTDATA`,
# then to a sibling checkout of go-hep — the same resolution `test/corpus.jl`
# does. Re-run it when the corpus changes; a change in this package should never
# require it.

using TTree

include(joinpath(@__DIR__, "..", "test", "corpus.jl"))

const DATA = normpath(joinpath(@__DIR__, "..", "test", "data"))

# The macro walks the corpus twice over: once counting, once dumping values. It
# is C++ because only ROOT can say what ROOT thinks a file contains, and reading
# the values through `TLeaf::GetValuePointer` is how ROOT itself would.
const MACRO = raw"""
#include <algorithm>
#include <cstdio>
#include <vector>

static const char *CORPUS = "@CORPUS@";
static const char *OUTDIR = "@OUTDIR@";

void collect(TObjArray *bs, std::vector<TBranch *> &out) {
  if (!bs) return;
  for (int i = 0; i < bs->GetEntriesFast(); ++i) {
    TBranch *b = (TBranch *)bs->At(i);
    out.push_back(b);
    collect(b->GetListOfBranches(), out);
  }
}

bool plainLeaf(TLeaf *l) {
  TString c = l->ClassName();
  return c == "TLeafO" || c == "TLeafB" || c == "TLeafS" || c == "TLeafI" ||
         c == "TLeafL" || c == "TLeafG" || c == "TLeafF" || c == "TLeafD" ||
         c == "TLeafF16" || c == "TLeafD32" || c == "TLeafC";
}

// Full precision, so that the reader parses back exactly the value ROOT held.
void writeValue(FILE *out, TLeaf *l, int i) {
  TString t = l->GetTypeName();
  void *p = l->GetValuePointer();
  if (t == "Float_t" || t == "Float16_t") fprintf(out, "%.9g", (double)((Float_t *)p)[i]);
  else if (t == "Double_t" || t == "Double32_t") fprintf(out, "%.17g", ((Double_t *)p)[i]);
  else if (t == "Long64_t") fprintf(out, "%lld", (long long)((Long64_t *)p)[i]);
  else if (t == "ULong64_t") fprintf(out, "%llu", (unsigned long long)((ULong64_t *)p)[i]);
  else if (t == "Long_t") fprintf(out, "%ld", ((Long_t *)p)[i]);
  else if (t == "ULong_t") fprintf(out, "%lu", ((ULong_t *)p)[i]);
  else if (t == "Int_t") fprintf(out, "%d", ((Int_t *)p)[i]);
  else if (t == "UInt_t") fprintf(out, "%u", ((UInt_t *)p)[i]);
  else if (t == "Short_t") fprintf(out, "%d", (int)((Short_t *)p)[i]);
  else if (t == "UShort_t") fprintf(out, "%u", (unsigned)((UShort_t *)p)[i]);
  else if (t == "Char_t") fprintf(out, "%d", (int)((Char_t *)p)[i]);
  else if (t == "UChar_t") fprintf(out, "%u", (unsigned)((UChar_t *)p)[i]);
  else if (t == "Bool_t") fprintf(out, "%d", (int)((Bool_t *)p)[i]);
  else fprintf(out, "?%s", t.Data());
}

int countBranches(TObjArray *bs) {
  int n = 0;
  if (!bs) return 0;
  for (int i = 0; i < bs->GetEntriesFast(); ++i) {
    TBranch *b = (TBranch *)bs->At(i);
    n += 1 + countBranches(b->GetListOfBranches());
  }
  return n;
}

void dumpTree(TTree *t, const char *fn, const char *tn) {
  printf("TREE\t%s\t%s\t%lld\t%d\t%d\n", fn, tn, (long long)t->GetEntries(),
         countBranches(t->GetListOfBranches()),
         (int)t->GetListOfLeaves()->GetEntriesFast());

  std::vector<TBranch *> bs;
  collect(t->GetListOfBranches(), bs);
  std::vector<std::pair<TBranch *, TLeaf *> > sel;
  for (size_t k = 0; k < bs.size(); ++k) {
    TObjArray *ls = bs[k]->GetListOfLeaves();
    for (int i = 0; i < ls->GetEntriesFast(); ++i) {
      TLeaf *l = (TLeaf *)ls->At(i);
      if (plainLeaf(l)) sel.push_back(std::make_pair(bs[k], l));
    }
  }
  if (sel.empty()) return;

  TString safe = TString::Format("%s__%s", fn, tn);
  safe.ReplaceAll("/", "_");
  FILE *out = fopen(TString::Format("%s/%s.txt", OUTDIR, safe.Data()), "w");
  Long64_t n = t->GetEntries();
  for (size_t k = 0; k < sel.size(); ++k) {
    TBranch *b = sel[k].first;
    TLeaf *l = sel[k].second;
    fprintf(out, "LEAF\t%s\t%s\t%s\t%s\t%lld\n", b->GetName(), l->GetName(),
            l->ClassName(), l->GetTypeName(), (long long)n);
    for (Long64_t e = 0; e < n; ++e) {
      t->GetEntry(e);
      if (TString(l->ClassName()) == "TLeafC") {
        // One string per line, so a newline inside one is stood in for.
        const char *s = (const char *)l->GetValuePointer();
        for (; *s; ++s) fputc(*s == '\n' ? '\001' : *s, out);
        fputc('\n', out);
        continue;
      }
      int len = l->GetLen();
      for (int i = 0; i < len; ++i) {
        if (i) fputc(' ', out);
        writeValue(out, l, i);
      }
      fputc('\n', out);
    }
  }
  fclose(out);
}

// A histogram is summarised rather than dumped: the corpus has 100000-cell
// histograms in it, and what the tests need is enough of ROOT's answer to catch
// a member read at the wrong width or in the wrong order. The sums cover every
// cell; the sampled cells pin down where the underflow is and which way round a
// two-dimensional array runs.
void sampleCells(FILE *out, TH1 *h, const char *fn, const char *nm) {
  Int_t n = h->GetNcells();
  Int_t idx[5] = {0, 1, 2, n / 2, n - 1};
  for (int i = 0; i < 5; ++i) {
    if (idx[i] < 0 || idx[i] >= n) continue;
    if (i && idx[i] == idx[i - 1]) continue;
    fprintf(out, "CELL\t%s\t%s\t%d\t%.17g\t%.17g\n", fn, nm, idx[i],
            h->GetBinContent(idx[i]), h->GetBinError(idx[i]));
  }
}

void dumpHist(TH1 *h, const char *fn, const char *nm) {
  double sumc = 0, sume = 0;
  for (Int_t i = 0; i < h->GetNcells(); ++i) {
    sumc += h->GetBinContent(i);
    sume += h->GetBinError(i);
  }
  TAxis *x = h->GetXaxis();
  TString labels;
  if (x->GetLabels()) {
    TIter next(x->GetLabels());
    while (TObject *o = next()) {
      if (labels.Length()) labels += ",";
      labels += o->GetName();
    }
  }
  printf("HIST\t%s\t%s\t%s\t%.17g\t%d\t%d\t%d\t%d\t%.17g\t%.17g\t%.17g\t%.17g\t%.17g\t%s\n",
         fn, nm, h->ClassName(), h->GetEntries(), h->GetNcells(), x->GetNbins(),
         h->GetYaxis()->GetNbins(), h->GetZaxis()->GetNbins(), sumc, sume,
         x->GetBinLowEdge(1), x->GetBinUpEdge(x->GetNbins()),
         x->GetBinLowEdge(x->GetNbins() / 2 + 1),
         labels.Length() ? labels.Data() : "-");
  sampleCells(stdout, h, fn, nm);
}

void dumpGraph(TGraph *g, const char *fn, const char *nm) {
  Int_t n = g->GetN();
  double sx = 0, sy = 0;
  for (Int_t i = 0; i < n; ++i) { sx += g->GetPointX(i); sy += g->GetPointY(i); }
  printf("GRAPH\t%s\t%s\t%s\t%d\t%.17g\t%.17g\n", fn, nm, g->ClassName(), n, sx, sy);
  for (Int_t i = 0; i < n && i < 4; ++i)
    printf("POINT\t%s\t%s\t%d\t%.17g\t%.17g\t%.17g\t%.17g\t%.17g\t%.17g\n", fn, nm, i,
           g->GetPointX(i), g->GetPointY(i), g->GetErrorXlow(i), g->GetErrorXhigh(i),
           g->GetErrorYlow(i), g->GetErrorYhigh(i));
}

void walk(TDirectory *d, const char *fn, TString prefix) {
  TIter next(d->GetListOfKeys());
  TKey *k;
  while ((k = (TKey *)next())) {
    TString cls = k->GetClassName();
    TString nm = prefix + k->GetName();
    if (cls == "TDirectoryFile") walk((TDirectory *)k->ReadObj(), fn, nm + "/");
    else if (cls == "TTree" || cls == "TNtuple" || cls == "TNtupleD")
      dumpTree((TTree *)k->ReadObj(), fn, nm.Data());
    else {
      TClass *c = TClass::GetClass(cls);
      if (!c) continue;
      // The classes this package knows, by name rather than by inheritance:
      // ROOT has graph classes it does not read, and one that is skipped is
      // not one that is read wrongly.
      if (c->InheritsFrom(TH1::Class()) &&
          (cls.BeginsWith("TH1") || cls.BeginsWith("TH2") || cls.BeginsWith("TH3") ||
           cls == "TProfile" || cls == "TProfile2D"))
        dumpHist((TH1 *)k->ReadObj(), fn, nm.Data());
      else if (cls == "TGraph" || cls == "TGraphErrors" || cls == "TGraphAsymmErrors")
        dumpGraph((TGraph *)k->ReadObj(), fn, nm.Data());
    }
  }
}

void dump() {
  gSystem->mkdir(OUTDIR, kTRUE);
  TSystemDirectory sd("testdata", CORPUS);
  std::vector<TString> names;
  TIter next(sd.GetListOfFiles());
  TSystemFile *sf;
  while ((sf = (TSystemFile *)next())) {
    TString n = sf->GetName();
    if (!sf->IsDirectory() && n.EndsWith(".root")) names.push_back(n);
  }
  std::sort(names.begin(), names.end(),
            [](const TString &a, const TString &b) { return strcmp(a.Data(), b.Data()) < 0; });
  for (size_t i = 0; i < names.size(); ++i) {
    TFile *f = TFile::Open(TString::Format("%s/%s", CORPUS, names[i].Data()));
    if (!f || f->IsZombie()) { printf("OPENFAIL\t%s\n", names[i].Data()); continue; }
    walk(f, names[i].Data(), "");
    f->Close();
  }
  printf("ROOTVERSION\t%s\n", gROOT->GetVersion());
}
"""

# ROOT's spelling of a leaf's C++ type, as the Julia type this package decodes
# it into. The class name alone will not do: an unsigned leaf has the same class
# as a signed one, and only the type name tells them apart.
const JULIA_TYPE = Dict(
    "Bool_t" => Bool,
    "Char_t" => Int8,
    "UChar_t" => UInt8,
    "Short_t" => Int16,
    "UShort_t" => UInt16,
    "Int_t" => Int32,
    "UInt_t" => UInt32,
    "Long_t" => Int64,
    "ULong_t" => UInt64,
    "Long64_t" => Int64,
    "ULong64_t" => UInt64,
    "Float_t" => Float32,
    "Float16_t" => Float32,
    "Double_t" => Float64,
    "Double32_t" => Float64,
)

parseval(::Type{Bool}, s) = parse(Int, s) != 0
parseval(::Type{T}, s) where {T} = parse(T, s)

"Split a dump file into `(branch, leaf, class, typename, entrylines)` records."
function records(path)
    out = Tuple{String,String,String,String,Vector{String}}[]
    lines = readlines(path)
    i = 1
    while i <= length(lines)
        f = split(lines[i], '\t')
        f[1] == "LEAF" || error("$path:$i: not a leaf header: $(lines[i])")
        n = parse(Int, f[6])
        push!(out, (f[2], f[3], f[4], f[5], lines[(i + 1):(i + n)]))
        i += n + 1
    end
    return out
end

function main(corpus)
    isdir(corpus) || error("no corpus at $corpus")
    mktempdir() do tmp
        dumps = joinpath(tmp, "dump")
        path = joinpath(tmp, "dump.C")
        write(path, replace(MACRO, "@CORPUS@" => corpus, "@OUTDIR@" => dumps))
        out = read(`root -l -b -q $path`, String)

        occursin("OPENFAIL", out) && error("ROOT could not open:\n$out")
        m = match(r"ROOTVERSION\t(\S+)", out)
        m === nothing && error("could not determine the ROOT version:\n$out")
        vers = m.captures[1]

        trees = [split(l, '\t') for l in eachline(IOBuffer(out)) if startswith(l, "TREE\t")]
        mkpath(DATA)

        open(joinpath(DATA, "corpus_structure.txt"), "w") do io
            println(io, "# Every tree in the corpus as ROOT ", vers, " counts it.")
            println(io, "# Generated by dev/gen_corpus_reference.jl — do not edit.")
            println(io, "#")
            println(io, "# file\ttree\tentries\tbranches\tleaves")
            for t in trees
                println(io, join(t[2:end], '\t'))
            end
        end

        nleaf = 0
        open(joinpath(DATA, "corpus_leaves.txt"), "w") do io
            println(io, "# Every plain leaf in the corpus as ROOT ", vers, " reads it.")
            println(io, "# Generated by dev/gen_corpus_reference.jl — do not edit.")
            println(io, "#")
            println(io, "# The digest is `leafdigest` in test/corpus.jl, over the values")
            println(io, "# ROOT reported, parsed as the Julia type its C++ type maps to.")
            println(io, "#")
            println(io, "# file\ttree\tbranch\tleaf\tclass\tentries\tvalues\tdigest")
            for t in trees
                fn, tn = t[2], t[3]
                dp = joinpath(dumps, string(fn, "__", replace(tn, "/" => "_"), ".txt"))
                isfile(dp) || continue
                for (bname, lname, cls, tname, lines) in records(dp)
                    entries, nvals = if cls == "TLeafC"
                        [(s,) for s in lines], length(lines)
                    else
                        T = get(JULIA_TYPE, tname) do
                            return error("$fn/$tn/$bname.$lname: unknown leaf type $tname")
                        end
                        vs = [
                            [parseval(T, s) for s in split(l) if !isempty(s)] for l in lines
                        ]
                        vs, sum(length, vs; init=0)
                    end
                    println(
                        io,
                        join(
                            (
                                fn,
                                tn,
                                bname,
                                lname,
                                cls,
                                length(lines),
                                nvals,
                                string(leafdigest(entries); base=16),
                            ),
                            '\t',
                        ),
                    )
                    nleaf += 1
                end
            end
        end

        # The histogram rows come back in walk order, and a CELL or POINT row
        # belongs to the HIST or GRAPH row above it — so they are written out
        # in the order ROOT produced them and read back the same way.
        objrows = [
            l for l in eachline(IOBuffer(out)) if startswith(l, "HIST\t") ||
                startswith(l, "CELL\t") ||
                startswith(l, "GRAPH\t") ||
                startswith(l, "POINT\t")
        ]
        nobj = count(l -> startswith(l, "HIST\t") || startswith(l, "GRAPH\t"), objrows)

        open(joinpath(DATA, "corpus_hists.txt"), "w") do io
            println(
                io, "# Every histogram and graph in the corpus as ROOT ", vers, " reads it."
            )
            println(io, "# Generated by dev/gen_corpus_reference.jl — do not edit.")
            println(io, "#")
            println(io, "# HIST\tfile\tpath\tclass\tentries\tncells\tnx\tny\tnz")
            println(io, "#     \tsum(content)\tsum(error)\txlow\txhigh\tmidedge\tlabels")
            println(io, "# CELL\tfile\tpath\tcell\tcontent\terror")
            println(io, "# GRAPH\tfile\tpath\tclass\tpoints\tsum(x)\tsum(y)")
            println(io, "# POINT\tfile\tpath\tindex\tx\ty\texlow\texhigh\teylow\teyhigh")
            println(io, "#")
            println(
                io, "# Cells are ROOT's numbering, so cell 0 is the underflow. `midedge`"
            )
            println(
                io, "# is the low edge of the middle bin, which is where an axis with a"
            )
            println(io, "# variable binning differs from one without.")
            for l in objrows
                println(io, l)
            end
        end

        return println(
            "ROOT ",
            vers,
            ": ",
            length(trees),
            " trees, ",
            nleaf,
            " leaves, ",
            nobj,
            " histograms and graphs -> ",
            DATA,
        )
    end
    return 0
end

exit(main(isempty(ARGS) ? corpus_dir() : ARGS[1]))
