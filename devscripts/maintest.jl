using Revise
using DiskArrayEngine
using DiskArrays: ChunkType, RegularChunks
using Statistics

using Zarr, DiskArrays, OffsetArrays
using DiskArrayEngine: ProcessingSteps, MWOp, subset_step_to_chunks, PickAxisArray, internal_size, ProductArray, InputArray, getloopinds, UserOp, mysub, ArrayBuffer, NoFilter, AllMissing,
  NonMutatingFunction, create_buffers, read_range, wrap_outbuffer, generate_inbuffers, generate_outbuffers, get_bufferindices, offset_from_range, generate_outbuffer_collection, put_buffer, 
  Output, _view, Input, applyfilter, apply_function, LoopWindows, GMDWop, results_as_diskarrays
using StatsBase: rle
using CFTime: timedecode
using Dates
using OnlineStats
a = zopen("/home/fgans/data/esdc-8d-0.25deg-184x90x90-2.1.1.zarr/air_temperature_2m/", fill_as_missing=true)

t = zopen("/home/fgans/data/esdc-8d-0.25deg-184x90x90-2.1.1.zarr/time/", fill_as_missing=true)
t.attrs["units"]
tvec = timedecode(t[:],t.attrs["units"])
years, nts = rle(yearmonth.(tvec))
cums = [0;cumsum(nts)]

stepvectime = [cums[i]+1:cums[i+1] for i in 1:length(nts)]


stepveclat = ProcessingSteps(0,1:size(a,2))
stepveclon = ProcessingSteps(0,1:size(a,1))

#Chunks over the loop indices


#First example: Latitudinal mean of monthly average
o1 = MWOp(eachchunk(a).chunks[1])
o2 = MWOp(eachchunk(a).chunks[2])
o3 = MWOp(eachchunk(a).chunks[3],steps=stepvectime)

ops = (o1,o2,o3)




rp = ProductArray((o1.steps,o2.steps,o3.steps))

# rangeproduct[3]


inars = (InputArray(a,LoopWindows(rp,Val((1,2,3)))),)


outsize = length.((stepveclat,stepvectime))
o1 = MWOp(DiskArrays.RegularChunks(1,0,outsize[1]))
o2 = MWOp(DiskArrays.RegularChunks(1,0,outsize[2]))
outrp = ProductArray((o1.steps,o2.steps))
outwindows = (LoopWindows(outrp,Val((2,3))),)

function myfunc(x)
    all(ismissing,x) ? (0,zero(eltype(x))) : (1,mean(skipmissing(x)))
end

mainfunc = NonMutatingFunction(myfunc)
function reducefunc((n1,s1),(n2,s2))
  (n1+n2,s1+s2)
end
init = (0,zero(Float64))
filters = (NoFilter(),)
fin(x) = last(x)/first(x)
outtypes = (Union{Float32,Missing},)
args = ()
kwargs = (;)
f = UserOp(mainfunc,reducefunc,init,filters,fin,outtypes,args,kwargs)


function myfunc!(xout,x)
  if !all(ismissing,x) 
    fit!(xout[],mean(skipmissing(x)))
  end
end

mainfunc = DiskArrayEngine.MutatingFunction(myfunc!)
init = ()->OnlineStats.Mean()
filters = (NoFilter(),)
fin(x) = nobs(x) == 0 ? missing : OnlineStats.value(x)
outtypes = (Union{Float32,Missing},)
args = ()
kwargs = (;)
f = UserOp(mainfunc,OnlineStats.merge!,init,filters,fin,outtypes,args,kwargs)


optotal = GMDWop(inars, outwindows, f)


r, = results_as_diskarrays(optotal)
rsub = r[300:310,200:210]





loopranges = ProductArray((eachchunk(a).chunks[1:2]...,DiskArrays.RegularChunks(120,0,480)))
b = zeros(Union{Float32,Missing},size(a,2),length(stepvectime));
outars = (InputArray(b,outwindows[1]),)
DiskArrayEngine.run_loop(optotal,loopranges,outars)

b

using Plots
heatmap(b)