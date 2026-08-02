"""
    TTree.Trees

Layer 4: `TTree` and everything under it — branches, leaves, baskets, and the
values they hold.

A tree is metadata: it names its columns and says where on the file each of
their baskets was written. Reading one column therefore touches only that
column's baskets, which is the property the whole format exists to provide and
which this layer preserves — [`array`](@ref) materialises a branch,
[`eachchunk`](@ref) streams it a basket at a time.

Unlike the classes in [`TTree.Objects`](@ref), the tree classes are streamed by
ROOT automatically, from the description stored in the file rather than from any
layout fixed in code. So they are read that way here too — see
[`layout`](@ref) — while the write side emits one current version. That is the
one place in this package where the two directions are not mirror images.
"""
module Trees

using ..Bytes
using ..Bytes: Bytes
using ..Compress
using ..Compress: Compress
using ..IOFS
using ..IOFS: IOFS
using ..Objects
using ..Objects:
    Objects,
    base_type,
    headerclass,
    is_container,
    julia_type,
    layout,
    read_count,
    read_counted,
    read_many,
    read_objarray!,
    read_pointer_array,
    read_scalar,
    readbody,
    scalar_type,
    unknown_member,
    write_objarray!,
    write_pointer_array!

# `entries` means the same thing for a tree as it does for a histogram, so both
# are methods of the one function the object layer declares.
import ..Objects: entries

export Tree,
    TNtuple,
    TNtupleD,
    AnyTree,
    treecore,
    TBranch,
    TBranchElement,
    TBranchObject,
    TBranchRef,
    TIOFeatures,
    Leaf,
    TLeafO,
    TLeafB,
    TLeafS,
    TLeafI,
    TLeafL,
    TLeafG,
    TLeafF,
    TLeafD,
    TLeafF16,
    TLeafD32,
    TLeafC,
    TLeafElement,
    TLeafObject,
    AnyBranch,
    AnyLeaf,
    Basket,
    array,
    allbranches,
    branches,
    branchcore,
    leaves,
    leafcore,
    entries,
    owner,
    countleaf,
    elementtype,
    valuesize,
    isjagged,
    isobjectbranch,
    nbaskets,
    basket,
    eachbasket,
    eachchunk,
    BranchChunks,
    ObjectChunks,
    entrybytes,
    read_basket

include("iofeatures.jl")
include("leaf.jl")
include("branch.jl")
include("basket.jl")
include("tree.jl")
include("array.jl")
include("element.jl")

for (cls, ctor) in (
    "ROOT::TIOFeatures" => TIOFeatures,
    "TTree" => Tree,
    "TNtuple" => TNtuple,
    "TNtupleD" => TNtupleD,
    "TBranch" => TBranch,
    "TBranchElement" => TBranchElement,
    "TBranchObject" => TBranchObject,
    "TBranchRef" => TBranchRef,
    "TLeaf" => Leaf,
    "TLeafO" => TLeafO,
    "TLeafB" => TLeafB,
    "TLeafS" => TLeafS,
    "TLeafI" => TLeafI,
    "TLeafL" => TLeafL,
    "TLeafG" => TLeafG,
    "TLeafF" => TLeafF,
    "TLeafD" => TLeafD,
    "TLeafF16" => TLeafF16,
    "TLeafD32" => TLeafD32,
    "TLeafC" => TLeafC,
    "TLeafElement" => TLeafElement,
    "TLeafObject" => TLeafObject,
    "TBasket" => Basket,
)
    Objects.register_class!(cls, ctor)
end

end # module Trees
