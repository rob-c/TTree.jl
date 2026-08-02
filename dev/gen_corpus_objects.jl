# Regenerate `test/data/corpus_objects.txt` — what ROOT says is inside every
# object branch in the test corpus.
#
# A plain leaf holds a number, and `dev/gen_corpus_reference.jl` can dump one
# with `TLeaf::GetValuePointer`. An object branch holds a C++ object, so there
# is no pointer to dump: the only way to ask ROOT what it read is to read the
# object back and walk it — down its base classes, through its members, into
# whatever containers those members are. That is what the macro below does,
# writing each value out in the same canonical spelling `objectcanon` in
# test/corpus.jl writes it, so the two can be compared as bytes.
#
# Usage, from the package root:
#
#     julia --project=. dev/gen_corpus_objects.jl [corpus-dir]
#
# Requires a `root` on PATH. The corpus directory defaults to `TTREE_TESTDATA`,
# then to a sibling checkout of go-hep — the same resolution `test/corpus.jl`
# does. Re-run it when the corpus changes; a change in this package should never
# require it.

using TTree

include(joinpath(@__DIR__, "..", "test", "corpus.jl"))

const DATA = normpath(joinpath(@__DIR__, "..", "test", "data"))

# The canonical spelling, which both sides of the comparison have to agree on:
#
#     i<dec>            a signed integer
#     u<dec>            an unsigned integer
#     b0 / b1           a bool
#     f<8 hex digits>   a float, as its bit pattern
#     d<16 hex digits>  a double, as its bit pattern
#     s<len>:<bytes>    a string, TString or std::string alike
#     t<dec>            a TDatime, as the packed number ROOT stores
#     [<n>:<values>]    a sequence: a container, a fixed array, a counted member
#     {<n>:<name>=<v>…} an object, its base classes named as members
#
# Floats go out as bit patterns because a decimal spelling would compare two
# roundings rather than two values. A sequence is spelled the same whether it
# came from a container or from a `[10]` array, and a multidimensional array is
# flattened in C order — the order ROOT streams it in. An unordered container is
# spelled sorted, since what ROOT iterates there is the bucket order its own
# hash produced on reading rather than the order the elements were written in.
const MACRO = raw"""
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <set>
#include <string>
#include <vector>

static const char *CORPUS = "@CORPUS@";

// TVirtualStreamerInfo::EReadWrite, spelled out rather than qualified so that
// nothing here depends on which of ROOT's headers the interpreter has seen.
static const int T_OFFSET_L = 20;   // member is a fixed-size array
static const int T_OFFSET_P = 40;   // member is a pointer with a count
static const int T_OBJECT = 61;
static const int T_ANY = 62;
static const int T_OBJECT_P_1 = 63; // kObjectp
static const int T_OBJECT_P_2 = 64; // kObjectP
static const int T_TSTRING = 65;
static const int T_TOBJECT = 66;
static const int T_TNAMED = 67;
static const int T_ANY_P_1 = 68;    // kAnyp
static const int T_ANY_P_2 = 69;    // kAnyP
static const int T_STL_P = 71;
static const int T_STL = 300;
static const int T_STL_STRING = 365;

static void emitObject(std::string &out, char *addr, TClass *cl);

static void emitDec(std::string &out, char tag, long long v) {
  char buf[32];
  snprintf(buf, sizeof buf, "%c%lld", tag, v);
  out += buf;
}

static void emitUDec(std::string &out, char tag, unsigned long long v) {
  char buf[32];
  snprintf(buf, sizeof buf, "%c%llu", tag, v);
  out += buf;
}

static void emitFloat(std::string &out, float v) {
  unsigned int u;
  memcpy(&u, &v, 4);
  char buf[16];
  snprintf(buf, sizeof buf, "f%08x", u);
  out += buf;
}

static void emitDouble(std::string &out, double v) {
  unsigned long long u;
  memcpy(&u, &v, 8);
  char buf[32];
  snprintf(buf, sizeof buf, "d%016llx", u);
  out += buf;
}

static void emitString(std::string &out, const char *s, size_t n) {
  char buf[32];
  snprintf(buf, sizeof buf, "s%lu:", (unsigned long)n);
  out += buf;
  out.append(s, n);
}

static void openSeq(std::string &out, long long n) {
  char buf[32];
  snprintf(buf, sizeof buf, "[%lld:", n);
  out += buf;
}

// One number, at `p`, of the basic type `t` — the same codes a streamer element
// carries and a collection proxy reports.
static bool emitBasic(std::string &out, char *p, int t) {
  switch (t) {
    case 18: emitDec(out, 'b', *(Bool_t *)p ? 1 : 0); return true;
    case 1:  emitDec(out, 'i', *(Char_t *)p); return true;
    case 2:  emitDec(out, 'i', *(Short_t *)p); return true;
    case 3:
    case 6:  emitDec(out, 'i', *(Int_t *)p); return true;
    case 4:  emitDec(out, 'i', *(Long_t *)p); return true;
    case 16: emitDec(out, 'i', *(Long64_t *)p); return true;
    case 5:
    case 19: emitFloat(out, *(Float_t *)p); return true;
    case 8:
    case 9:  emitDouble(out, *(Double_t *)p); return true;
    case 11: emitUDec(out, 'u', *(UChar_t *)p); return true;
    case 12: emitUDec(out, 'u', *(UShort_t *)p); return true;
    case 13:
    case 15: emitUDec(out, 'u', *(UInt_t *)p); return true;
    case 14: emitUDec(out, 'u', *(ULong_t *)p); return true;
    case 17: emitUDec(out, 'u', *(ULong64_t *)p); return true;
  }
  return false;
}

static int basicSize(int t) {
  switch (t) {
    case 1: case 11: case 18: return 1;
    case 2: case 12: return 2;
    case 3: case 6: case 5: case 13: case 15: case 19: return 4;
    case 4: case 14: case 16: case 17: case 8: case 9: return 8;
  }
  return 0;
}

static void emitBasicArray(std::string &out, char *p, int t, long long n) {
  int sz = basicSize(t);
  openSeq(out, n);
  for (long long i = 0; i < n; ++i) {
    if (!sz || !emitBasic(out, p + i * sz, t)) { out += "?basic"; break; }
  }
  out += "]";
}

// A container, through the proxy ROOT uses for it. A map's value class is the
// pair, so nothing here needs to know a map from a vector.
static bool emitCollection(std::string &out, char *p, TClass *cl) {
  TVirtualCollectionProxy *px = cl->GetCollectionProxy();
  if (!px) return false;
  // What ROOT iterates in an unordered container is the bucket order its own
  // hash produced while reading, not the order the elements were written in.
  // So there is no order here to compare, and both sides sort instead.
  bool unordered = strstr(cl->GetName(), "unordered_") != 0;
  TVirtualCollectionProxy::TPushPop helper(px, p);
  UInt_t n = px->Size();
  TClass *vc = px->GetValueClass();
  int vt = px->GetType();
  std::vector<std::string> parts;
  for (UInt_t i = 0; i < n; ++i) {
    char *e = (char *)px->At(i);
    std::string one;
    if (vc) emitObject(one, e, vc);
    else if (!emitBasic(one, e, vt)) one = "?element";
    parts.push_back(one);
    if (one == "?element") break;
  }
  if (unordered) std::sort(parts.begin(), parts.end());
  openSeq(out, (long long)n);
  for (size_t i = 0; i < parts.size(); ++i) out += parts[i];
  out += "]";
  return true;
}

// One object at `addr`. The classes that stream themselves are spelled out; the
// rest are walked through their streamer info, base classes included as members
// named for the base.
static void emitObject(std::string &out, char *addr, TClass *cl) {
  if (!cl || !addr) { out += "?object"; return; }
  TString n = cl->GetName();
  if (n == "TString") {
    TString *s = (TString *)addr;
    emitString(out, s->Data(), (size_t)s->Length());
    return;
  }
  if (n == "string") {
    std::string *s = (std::string *)addr;
    emitString(out, s->data(), s->size());
    return;
  }
  if (n == "TDatime") {
    emitUDec(out, 't', ((TDatime *)addr)->Get());
    return;
  }
  if (n == "TObject") {
    // The top byte of fBits is memory state — kIsOnHeap and kNotDeleted are set
    // by the constructor and never written — so only the stored bits count.
    TObject *o = (TObject *)addr;
    out += "{2:fUniqueID=";
    emitUDec(out, 'u', o->GetUniqueID());
    out += "fBits=";
    emitUDec(out, 'u', (unsigned long long)(o->TestBits(0xffffffff) & 0x00ffffff));
    out += "}";
    return;
  }
  if (emitCollection(out, addr, cl)) return;

  TVirtualStreamerInfo *si = cl->GetStreamerInfo();
  if (!si) { out += "?streamer"; return; }
  TObjArray *els = si->GetElements();
  int ne = els ? els->GetEntriesFast() : 0;
  char buf[32];
  snprintf(buf, sizeof buf, "{%d:", ne);
  out += buf;
  for (int i = 0; i < ne; ++i) {
    TStreamerElement *el = (TStreamerElement *)els->At(i);
    out += el->GetName();
    out += "=";
    char *p = addr + el->GetOffset();
    int t = el->GetType();
    if (el->IsA() == TStreamerBase::Class()) {
      emitObject(out, p, TClass::GetClass(el->GetName()));
    } else if (t == T_STL || t == T_STL_STRING || t == T_STL + T_OFFSET_L) {
      emitObject(out, p, TClass::GetClass(el->GetTypeName()));
    } else if (t == T_STL_P) {
      emitObject(out, *(char **)p, TClass::GetClass(el->GetTypeName()));
    } else if (t == T_TSTRING) {
      TString *s = (TString *)p;
      emitString(out, s->Data(), (size_t)s->Length());
    } else if (t == T_OBJECT || t == T_ANY || t == T_TOBJECT || t == T_TNAMED) {
      emitObject(out, p, TClass::GetClass(el->GetTypeName()));
    } else if (t == T_OBJECT_P_1 || t == T_OBJECT_P_2 || t == T_ANY_P_1 ||
               t == T_ANY_P_2) {
      emitObject(out, *(char **)p, TClass::GetClass(el->GetTypeName()));
    } else if (t >= T_OFFSET_P && t < T_OFFSET_P + T_OFFSET_L) {
      // `Short_t *slice; //[N]` — the count is another member of this class.
      long long cnt = 0;
      TStreamerElement *ce =
          (TStreamerElement *)els->FindObject(((TStreamerBasicPointer *)el)->GetCountName());
      if (ce) {
        std::string cv;
        if (emitBasic(cv, addr + ce->GetOffset(), ce->GetType()))
          cnt = atoll(cv.c_str() + 1);
      }
      Int_t per = el->GetArrayLength() > 0 ? el->GetArrayLength() : 1;
      emitBasicArray(out, *(char **)p, t - T_OFFSET_P, cnt * per);
    } else if (t >= T_OFFSET_L && t < T_OFFSET_P) {
      emitBasicArray(out, p, t - T_OFFSET_L, el->GetArrayLength());
    } else if (!emitBasic(out, p, t)) {
      snprintf(buf, sizeof buf, "?type%d", t);
      out += buf;
    }
  }
  out += "}";
}

// The address of a branch's object, once an entry has been read into it.
static char *branchObject(TBranch *b) {
  if (b->InheritsFrom(TBranchElement::Class())) return ((TBranchElement *)b)->GetObject();
  // A TBranchObject's address is where the object *pointer* lives.
  char *a = b->GetAddress();
  return a ? *(char **)a : 0;
}

static bool objectBranch(TBranch *b) {
  return b->InheritsFrom(TBranchElement::Class()) ||
         b->InheritsFrom(TBranchObject::Class());
}

static const char *branchClass(TBranch *b) {
  return b->InheritsFrom(TBranchElement::Class())
             ? ((TBranchElement *)b)->GetClassName()
             : ((TBranchObject *)b)->GetClassName();
}

// The object branches of one tree, in the order they are indexed by.
static void objectBranches(TTree *t, std::vector<TBranch *> &out) {
  TObjArray *bs = t->GetListOfBranches();
  for (int i = 0; i < bs->GetEntriesFast(); ++i) {
    TBranch *b = (TBranch *)bs->At(i);
    if (objectBranch(b)) out.push_back(b);
  }
}

void listTree(TTree *t, const char *fn, const char *tn) {
  std::vector<TBranch *> bs;
  objectBranches(t, bs);
  for (size_t i = 0; i < bs.size(); ++i)
    printf("BRANCH\t%s\t%s\t%d\t%s\t%s\n", fn, tn, (int)i, bs[i]->GetName(),
           branchClass(bs[i]));
}

void walk(TDirectory *d, const char *fn, TString prefix) {
  TIter next(d->GetListOfKeys());
  TKey *k;
  while ((k = (TKey *)next())) {
    TString cls = k->GetClassName();
    TString nm = prefix + k->GetName();
    if (cls == "TDirectoryFile") walk((TDirectory *)k->ReadObj(), fn, nm + "/");
    else if (cls == "TTree" || cls == "TNtuple" || cls == "TNtupleD")
      listTree((TTree *)k->ReadObj(), fn, nm.Data());
  }
}

// Every C++ template a file mentions, whether as a class of its own or as the
// type of a member. Interpreting these rather than compiling them is what ROOT
// falls over on, so they are reported here and compiled before the read.
void listTypes(TFile *f) {
  std::set<std::string> seen;
  TList *sil = f->GetStreamerInfoList();
  TIter next(sil);
  TObject *o;
  while ((o = next())) {
    TStreamerInfo *si = dynamic_cast<TStreamerInfo *>(o);
    if (!si) continue;
    if (strchr(si->GetName(), '<')) seen.insert(si->GetName());
    TObjArray *els = si->GetElements();
    for (int i = 0; els && i < els->GetEntriesFast(); ++i) {
      TString tn = ((TStreamerElement *)els->At(i))->GetTypeName();
      while (tn.Length() && (tn[tn.Length() - 1] == '*' || tn[tn.Length() - 1] == ' '))
        tn.Remove(tn.Length() - 1);
      if (tn.Contains('<')) seen.insert(tn.Data());
    }
  }
  for (std::set<std::string>::iterator i = seen.begin(); i != seen.end(); ++i)
    printf("TYPE\t%s\n", i->c_str());
}

void dumpOne(TTree *t, int idx, const char *outpath) {
  std::vector<TBranch *> bs;
  objectBranches(t, bs);
  if (idx < 0 || idx >= (int)bs.size()) { printf("NOBRANCH\t%d\n", idx); return; }
  TBranch *b = bs[idx];
  const char *cls = branchClass(b);
  TClass *c = TClass::GetClass(cls);
  // A TBranchObject has nowhere to read into until it is given one.
  void *obj = 0;
  if (b->InheritsFrom(TBranchObject::Class())) {
    obj = c->New();
    b->SetAddress(&obj);
  }
  Long64_t n = t->GetEntries();
  std::string body;
  for (Long64_t e = 0; e < n; ++e) {
    // This branch and its sub-branches, not the whole entry: a tree here may
    // hold another branch ROOT cannot read, and reading it would take the
    // process down along with the answer for this one.
    b->GetEntry(e);
    emitObject(body, branchObject(b), c);
  }
  FILE *out = fopen(outpath, "w");
  fprintf(out, "OBJ\t%s\t%s\t%lld\t%lu\n", b->GetName(), cls, (long long)n,
          (unsigned long)body.size());
  fwrite(body.data(), 1, body.size(), out);
  fputc('\n', out);
  fclose(out);
}

// One branch per process, for two reasons. Several corpus files define a class
// called `Event`, and they are not the same class — ROOT keeps one TClass per
// name, so whichever file was opened first would decide what `Event` means for
// the rest of the run. And ROOT 6.40 aborts outright on a few of the corpus's
// containers, for want of a compiled dictionary; in its own process that costs
// one branch's reference values rather than the whole run's.
//
// `mode` is "list" to report a file's object branches and the templates it
// mentions, and "one" to dump the branch at `idx` of the tree at `tn`. In "one"
// mode `types` is the semicolon-separated list "list" reported, compiled before
// the file is opened so that ROOT reads it with real dictionaries; the compiled
// dictionaries land in the working directory and are reused from there, so this
// costs a compile once rather than once a branch.
void dump(const char *mode, const char *fname, const char *tn, int idx,
          const char *outpath, const char *types) {
  if (types && *types)
    gInterpreter->GenerateDictionary(
        types, "vector;list;deque;forward_list;set;unordered_set;map;unordered_map;"
               "string;bitset;utility;TString.h");
  TFile *f = TFile::Open(TString::Format("%s/%s", CORPUS, fname));
  if (!f || f->IsZombie()) { printf("OPENFAIL\t%s\n", fname); return; }
  if (!strcmp(mode, "list")) {
    walk(f, fname, "");
    listTypes(f);
  } else {
    TTree *t = (TTree *)f->Get(tn);
    if (!t) { printf("NOTREE\t%s\n", tn); return; }
    dumpOne(t, idx, outpath);
  }
  printf("ROOTVERSION\t%s\n", gROOT->GetVersion());
  // ROOT's end-of-process cleanup deletes the emulated objects the read built,
  // and for several of the corpus's containers that is where it falls over —
  // after the answer is already in hand. Flush what was said and leave without
  // running a single destructor.
  fflush(0);
  gSystem->Exit(0, kFALSE);
}
"""

"""
    objectrecords(path) -> Vector{Tuple{String,String,Int,String}}

Split a dump file into `(branch, class, entries, canonical)` records. The
canonical text is byte-counted rather than line-delimited: a string inside an
object can hold anything, newlines included.
"""
function objectrecords(path)
    out = Tuple{String,String,Int,String}[]
    open(path, "r") do io
        while !eof(io)
            f = split(readline(io), '\t')
            f[1] == "OBJ" || error("$path: not an object header: $(join(f, '\t'))")
            body = String(read(io, parse(Int, f[5])))
            read(io, 1)  # the newline the dump puts after the body
            push!(out, (String(f[2]), String(f[3]), parse(Int, f[4]), body))
        end
    end
    return out
end

"""
    runroot(wd, macropath, args...) -> String

Run the macro once, in its own process and in `wd`, and hand back what it
printed. Text without a `ROOTVERSION` line is ROOT's parting complaint rather
than an answer — which for this corpus is a fact worth recording rather than an
error, so it is left to the caller to judge.
"""
function runroot(wd, macropath, args...)
    call = string(
        macropath, "(", join((a isa Integer ? string(a) : "\"$a\"" for a in args), ","), ")"
    )
    out = IOBuffer()
    err = IOBuffer()
    run(pipeline(ignorestatus(Cmd(`root -l -b -q $call`; dir=wd)); stdout=out, stderr=err))
    text = String(take!(out))
    occursin("ROOTVERSION\t", text) && return text
    # What ROOT complained about, for the record. The last diagnostic is the
    # one nearest the fall-over; the ones before it are often just grumbling.
    why = ""
    for l in Iterators.flatten((eachline(IOBuffer(text)), eachline(IOBuffer(take!(err)))))
        occursin(r"Fatal|Error in|Break|free\(\)|malloc\(\)|corruption", l) &&
            (why = strip(replace(l, r"\s+" => " ")))
    end
    return isempty(why) ? "ROOT stopped without saying why" : why
end

"""
    listbranches(wd, macropath, fn) -> (branches, types)

Every object branch ROOT sees in one corpus file, as `(tree, index, name,
class)`, and the templates the file mentions as one `;`-separated list.
"""
function listbranches(wd, macropath, fn)
    out = runroot(wd, macropath, "list", fn, "", 0, "", "")
    occursin("ROOTVERSION\t", out) || error("ROOT could not list $fn: $out")
    fields = [split(l, '\t') for l in eachline(IOBuffer(out))]
    bs = [
        (String(f[3]), parse(Int, f[4]), String(f[5]), String(f[6])) for
        f in fields if f[1] == "BRANCH"
    ]
    return bs, join((f[2] for f in fields if f[1] == "TYPE"), ';')
end

function main(corpus)
    isdir(corpus) || error("no corpus at $corpus")
    mktempdir() do tmp
        dumps = joinpath(tmp, "dump")
        mkpath(dumps)
        path = joinpath(tmp, "dump.C")
        write(path, replace(MACRO, "@CORPUS@" => corpus))

        vers = ""
        rows = String[]
        skips = String[]
        for fn in sort(filter(f -> endswith(f, ".root"), readdir(corpus)))
            bs, types = listbranches(tmp, path, fn)
            for (tn, idx, bname, cls) in bs
                dp = joinpath(dumps, "b.txt")
                rm(dp; force=true)
                out = runroot(tmp, path, "one", fn, tn, idx, dp, types)
                if !occursin("ROOTVERSION\t", out)
                    println("skipping $fn/$tn/$bname: ", out)
                    push!(skips, join((fn, tn, bname, cls, out), '\t'))
                    continue
                end
                vers = match(r"ROOTVERSION\t(\S+)", out).captures[1]
                for (_, _, n, body) in objectrecords(dp)
                    bad = findfirst('?', body)
                    bad === nothing || error(
                        "$fn/$tn/$bname: ROOT's walker did not know what to do here: " *
                        body[bad:min(end, bad + 40)],
                    )
                    push!(
                        rows,
                        join(
                            (
                                fn,
                                tn,
                                bname,
                                cls,
                                n,
                                ncodeunits(body),
                                string(objectdigest(body); base=16),
                            ),
                            '\t',
                        ),
                    )
                end
            end
        end

        mkpath(DATA)
        open(joinpath(DATA, "corpus_objects.txt"), "w") do io
            println(io, "# Every object branch in the corpus as ROOT ", vers, " reads it.")
            println(io, "# Generated by dev/gen_corpus_objects.jl — do not edit.")
            println(io, "#")
            println(io, "# The digest is `objectdigest` in test/corpus.jl, over the")
            println(io, "# canonical spelling `objectcanon` there produces — see that file")
            println(io, "# for what the spelling is and dev/gen_corpus_objects.jl for the")
            println(io, "# C++ that has to agree with it.")
            println(io, "#")
            println(io, "# OBJ\tfile\ttree\tbranch\tclass\tentries\tbytes\tdigest")
            println(io, "# NOREF\tfile\ttree\tbranch\tclass\twhat ROOT said")
            println(io, "#")
            println(io, "# A NOREF row is a branch this package reads and ROOT, without a")
            println(io, "# compiled dictionary for the class, does not: it aborts rather")
            println(io, "# than answer. Those branches have no reference values, and the")
            println(io, "# row is here to say so rather than to leave them looking absent.")
            for r in rows
                println(io, "OBJ\t", r)
            end
            for s in skips
                println(io, "NOREF\t", s)
            end
        end

        return println(
            "ROOT ",
            vers,
            ": ",
            length(rows),
            " object branches (",
            length(skips),
            " ROOT could not read) -> ",
            DATA,
        )
    end
    return 0
end

exit(main(isempty(ARGS) ? corpus_dir() : ARGS[1]))
