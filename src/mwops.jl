using DiskArrays: DiskArrays, ChunkType, GridChunks

internal_size(p) = last(last(p))-first(first(p))+1
function steps_per_chunk(p,cs::ChunkType)
    centers = map(x->(first(x)+last(x))/2,p)
    slen = sum(cs) do r
        i1 = searchsortedfirst(centers,first(r))
        i2 = searchsortedlast(centers,last(r))
        length(i1:i2)
    end
    slen/length(cs)
end

"""
Struct specifying the windows of a participating array along each dimension as well as 
the loop axes where this array participates in the loop
"""
struct LoopWindows{W,IL}
    windows::W
    lr::Val{IL}
end


struct InputArray{A,LW<:LoopWindows}
    a::A
    lw::LW
end


getdata(c::InputArray) = c.a
getloopinds(::LoopWindows{<:Any,IL}) where IL = IL 
getsubndims(::LoopWindows{<:Any,IL}) where IL = length(IL)
@inline getloopinds(c::InputArray) = getloopinds(c.lw)
@inline getsubndims(c::InputArray) = getsubndims(c.lw)


"""
    struct MWOp

A type holding information about the sliding window operation to be done over an existing dimension. 
Field names:

* `rtot` unit range denoting the full range of the operation
* `parentchunks` list of chunk structures of the parent arrays
* `w` size of the moving window, length-2 tuple with steps before and after center
* `steps` range denoting the center coordinates for each step of the op
* `outputs` ids of related outputs and indices of their dimension index
"""
struct MWOp{G<:ChunkType,P}
    rtot::UnitRange{Int64}
    parentchunks::G
    steps::P
    is_ordered::Bool
end
function MWOp(parentchunks; r = first(first(parentchunks)):last(last(parentchunks)), steps=ProcessingSteps(0,r),is_ordered=false)
    MWOp(r, parentchunks, steps, is_ordered)
end

mysub(ia,t) = map(li->t[li],getloopinds(ia))

"Returns the full domain that a `DiskArrays.ChunkType` object covers as a unit range"
domain_from_chunktype(ct) = first(first(ct)):last(last(ct))
"Returns the length of a dimension covered by a `DiskArrays.ChunkType` object"
length_from_chunktype(ct) = length(domain_from_chunktype(ct))


"Tests that a supplied list of parent chunks covers the same domain and returns this"
function range_from_parentchunks(pc)
    d = domain_from_chunktype(first(pc))
    for c in pc
        if domain_from_chunktype(c)!=d
            throw(ArgumentError("Supplied parent chunks cover different domains"))
        end
    end
    d
end



function getwindowsize(inars, outspecs)
    d = Dict{Int,Int}()
    for ia in (inars...,outspecs...)
      addsize!(ia.lw,d)
    end
    imax = maximum(keys(d))
    ntuple(i->d[i],imax)
  end
  function addsize!(ia,d)
    map(size(ia.windows),getloopinds(ia)) do s,li
      if haskey(d,li)
        if d[li] != s
          error("Inconsistent Loop windows")
        end
      else
        d[li] = s
      end
    end
  end

struct GMDWop{N,I,O,F<:UserOp}
    inars::I
    outspecs::O
    f::F
    windowsize::NTuple{N,Int}
end
function GMDWop(inars, outspecs, f)
    s = getwindowsize(inars, outspecs)
    GMDWop(inars,outspecs, f, s)
end


abstract type Emitter end
struct DirectEmitter end


abstract type Aggregator end

struct ReduceAggregator{F}
    op::F
end



