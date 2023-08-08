export results_as_diskarrays
using DiskArrays: AbstractDiskArray, RegularChunks
using OffsetArrays: OffsetArray

struct GMWOPResult{T,N,G<:GMDWop,CS,ISPEC} <: AbstractDiskArray{T,N}
    op::G
    ires::Val{ISPEC}
    chunksize::CS
    max_cache::Float64
    s::NTuple{N,Int}
  end
  getoutspec(r::GMWOPResult{<:Any,<:Any,<:Any,<:Any,ISPEC}) where ISPEC = r.op.outspecs[ISPEC]
  getioutspec(::GMWOPResult{<:Any,<:Any,<:Any,<:Any,ISPEC}) where ISPEC = ISPEC
  
  Base.size(r::GMWOPResult) = maximum.(maximum,getoutspec(r).lw.windows.members)
  
  function results_as_diskarrays(o::GMDWop;cs=nothing,max_cache=1e9)
    map(enumerate(o.outspecs)) do (i,outspec)
      T = o.f.outtype[i]
      N = ndims(outspec.lw.windows)
      cs = cs === nothing ? DiskArrays.Unchunked() : cs
      GMWOPResult{T,N,typeof(o),typeof(cs),i}(o,Val(i),cs,max_cache,size(outspec.lw.windows)) 
    end
  end
  
  
  function DiskArrays.readblock!(res::GMWOPResult, aout,r::AbstractUnitRange...)
    #Find out directly connected loop ranges
    s = res.op.windowsize
    s = Base.OneTo.(s)
    outars = ntuple(_->nothing,length(res.op.outspecs))
    outspec = getoutspec(res)
    foreach(getloopinds(outspec),r,outspec.lw.windows.members) do li,ri,w
      i1 = findfirst(a->maximum(a)>=first(ri),w)
      i2 = findlast(a->minimum(a)<=last(ri),w)
      s = Base.setindex(s,i1:i2,li)
    end
    outars = Base.setindex(outars,OffsetArray(aout,r...),getioutspec(res))
    l = length.(s)
    lres = mysub(outspec.lw,s)
    if length(lres) < length(l) && prod(l)*DiskArrays.element_size(res) > res.max_cache
      l = cut_looprange(l,res.max_cache)
    end
    loopranges = map(s,l) do si,cs
      map(RegularChunks(cs,0,length(si)),first(si)-1) do c,offs
        c.+offs
      end
    end
    loopranges = ProductArray(loopranges)
    runner = LocalRunner(res.op,loopranges,outars)
    run_loop(runner)
    nothing
  end