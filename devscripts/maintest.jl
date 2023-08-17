using Revise
using DiskArrayEngine
using DiskArrays: ChunkType, RegularChunks
using Statistics
using Zarr, DiskArrays, OffsetArrays
#using DiskArrayEngine: MWOp, internal_size, ProductArray, InputArray, getloopinds, UserOp, mysub, ArrayBuffer, NoFilter, AllMissing,
#  create_buffers, read_range, generate_inbuffers, generate_outbuffers, get_bufferindices, offset_from_range, generate_outbuffer_collection, put_buffer, 
#  Output, _view, Input, applyfilter, apply_function, LoopWindows, GMDWop, results_as_diskarrays, create_userfunction, steps_per_chunk, apparent_chunksize,
#  find_adjust_candidates, generate_LoopRange, get_loopsplitter, split_loopranges_threads, merge_loopranges_threads, LocalRunner, 
#  merge_outbuffer_collection, DistributedRunner
using StatsBase: rle
using CFTime: timedecode
using Dates
using OnlineStats
using Logging
using Distributed
#global_logger(SimpleLogger(stdout,Logging.Debug))
#global_logger(SimpleLogger(stdout))
using LoggingExtras
using Dagger

example_data = [
  [
    [:a=>1, :b=>2, :b=>3],
    [:b=>3, :b=>2, :a=>1],
  ], [
    [:a=>1, :c=>10, :d=>-1, :c=>10, :d=>-1],
    [:c=>11, :d=>-2, :d=>-2, :c=>11],
  ], [
    [:e=>3, :e=>3],
    [:e=>4, :e=>4, :a=>1],
  ]
]

#Kepp track of sum and count
function accumulate_data(x,agg) 
  for (name,val) in x
    n,s = get!(agg,name,(0,0))
    agg[name] = (n+1,s+val)
  end
  nothing
end


function merge_and_flush_outputs(aggregator)
  if isempty(aggregator)
    return nothing
  else
  merged_aggregator = fetch(reduce(aggregator) do d1, d2
    merge(fetch(d1),fetch(d2)) do (n1,s1),(n2,s2)
      n1+n2,s1+s2
    end
  end)
  for k in keys(merged_aggregator)
    n,s = merged_aggregator[k]
    if n==4
      @info "$k: $s"
      delete!(merged_aggregator,k)
    end
  end
  merged_aggregator
  end
end

include("partialshard.jl")
aggregator = Dagger.shard(;per_thread=true) do 
  Dict{Symbol,Tuple{Int,Int}}()
end;
r = map(example_data) do group
  Dagger.spawn(group) do group
    Dagger.spawn_sequential() do
      localaggregator = Dagger.shard(;per_thread=true) do
        Dict{Symbol,Tuple{Int,Int}}()
      end
      r = Dagger.spawn_bulk() do
        map(group) do subgroup
          Dagger.spawn(accumulate_data,subgroup,localaggregator)
        end
      end
      fetch.(r)
      aggregator_copies = Dagger.spawn_bulk() do
        map(localaggregator) do agg
          Dagger.spawn(copy,agg)
        end
      end
      # Merge and flush all aggregator copies
      unflushed_data = Dagger.@spawn merge_and_flush_outputs(aggregator_copies)
      @show group,fetch(unflushed_data)
      Dagger.spawn(unflushed_data,aggregator) do rem_data, agg
        merge!(agg,rem_data) do (n1,s1),(n2,s2)
          n1+n2,s1+s2
        end
      end
    end
  end
end;
fetch.(r);
merge_and_flush_outputs(aggregator);

fetch.(values(aggregator.chunks))

using Dagger, Distributed
addprocs(2)
@everywhere begin
  using Dagger, Distributed
  include("partialshard.jl")
end
s = partialshard(;per_thread=true) do
  Ref(0)
end
r = map(1:10) do _
  Dagger.spawn(s) do myacc
    oldacc = myacc[]
    myacc[] +=1
    println(oldacc[], " ",myacc[], " ",objectid(myacc)," ",myid())
    nothing
  end
end

sum(fetch.(r))

for a in s
  println(fetch(a))
end

map(values(s.chunks)) do v
  fetch(first(v))
end

r = fetch.(map(i->Dagger.spawn(getindex,i),s))

cs = Dagger.@shard Threads.Atomic{Int}(0)


aggregator.chunks

fetch.(values(aggregator.chunks))

r = Dagger.spawn() do
  1+1
end
fr = fetch(r, raw=true)


using Test

a = zopen("/home/fgans/data/esdc-8d-0.25deg-184x90x90-2.1.1.zarr/air_temperature_2m/", fill_as_missing=true);

t = zopen("/home/fgans/data/esdc-8d-0.25deg-184x90x90-2.1.1.zarr/time/", fill_as_missing=true);
tvec = timedecode(t[:],t.attrs["units"]);
years, nts = rle(yearmonth.(tvec));
nts;

#cums = [0;cumsum(nts)]
function outrepfromrle(nts)
  r = Int[]
  for i in 1:length(nts)
    for _ in 1:nts[i]
      push!(r,i)
    end
  end
  r
end
    


#stepvectime = [cums[i]+1:cums[i+1] for i in 1:length(nts)]
#length.(stepvectime)


stepveclat = 1:size(a,2);
stepveclon = 1:size(a,1);
outsteps = outrepfromrle(nts);



# rangeproduct[3]

inars = (InputArray(a),);

outars = (create_outwindows((720,480), dimsmap=(2,3),windows = (stepveclat,outsteps)),);

outpath = tempname()
b = zzeros(Float32,size(a,2),length(outsteps),chunks = (90,480),fill_as_missing=true,path=outpath);

f = disk_onlinestat(Mean)



optotal = GMDWop(inars, outars, f);

r,  = results_as_diskarrays(optotal);

r[2:3,2]

lr = DiskArrayEngine.optimize_loopranges(optotal,5e8,tol_low=0.2,tol_high=0.05,max_order=2);
chunks = getproperty.(lr.members,:cs)[2:3];

out1 = zzeros(Float32,720,480,path=tempname(),chunks=chunks,fill_as_missing=true,fill_value=-1f32);
r = DiskArrayEngine.LocalRunner(optotal,lr,(out1,),threaded=true)
run(r)


using Plots
heatmap(out1[:,:])

out2 = zzeros(Float32,720,480,path=tempname(),chunks=chunks,fill_as_missing=true,fill_value=-1f32);


rmprocs(workers())
addprocs(4,exeflags="--project=$(@__DIR__)")
@everywhere begin
using DiskArrayEngine
using DiskArrays: ChunkType, RegularChunks
using Statistics
using Zarr, DiskArrays, OffsetArrays
using StatsBase: rle
using CFTime: timedecode
using Dates
using OnlineStats
using Logging
using Distributed
  

  # using LoggingExtras

  # mylogger = EarlyFilteredLogger(ConsoleLogger(Logging.Debug)) do log
  #   (log._module == DiskArrayEngine && log.level >= Logging.Debug) || log.level >=Logging.Info
  # end
  # global_logger(mylogger)
  
end

# mylogger = TransformerLogger(ConsoleLogger(Logging.Debug)) do log
#   if length(string(log.message)) > 256
#       short_message = string(log.message)[1:min(end, 256)] * "..."
#       return merge(log, (;message=short_message))
#   else
#       return log
#   end
# end;
# global_logger(mylogger)
@time begin
  runner1 = DiskArrayEngine.DaggerRunner(optotal,lr,(out2,),threaded=true);
  run(runner1);
end


# out2 = zeros(Union{Float32,Missing},720,480)
# runner2 = LocalRunner(optotal,lr,(out2,),threaded=true)
# run(runner2)


using Plots
heatmap(out2[:,:])

unique(out1[:,:] - out2[:,:])

error()
out1[:,:]

# example_data = [
#   [
#     [:a=>1, :b=>2, :b=>3],
#     [:b=>3, :b=>2, :a=>1],
#   ], [
#     [:a=>1, :c=>10, :d=>-1, :c=>10, :d=>-1],
#     [:c=>11, :d=>-2, :d=>-2, :c=>11],
#   ], [
#     [:e=>3, :e=>3],
#     [:e=>4, :e=>4, :a=>1],
#   ]
# ]

# #Kepp track of sum and count
# function accumulate_data(x,agg) 
#   for (name,val) in x
#     n,s = get!(agg,name,(0,0))
#     agg[name] = (n+1,s+val)
#   end
#   nothing
# end

# function global_merge_and_flush_outputs(aggregator)
#   merged_aggregator = reduce(aggregator) do d1, d2
#     merge(d1,d2) do (n1,s1),(n2,s2)
#       n1+n2,s1+s2
#     end
#   end
#   for k in keys(merged_aggregator)
#     n,s = merged_aggregator[k]
#     @assert n==4
#     println("$k: $s")
#     delete!(merged_aggregator,k)
#   end
# end

# local_merge_and_flush_outputs(aggregator) = nothing


# using Dagger
# aggregator = Dagger.@shard per_thread=true Dict{Symbol,Tuple{Int,Int}}()
# r = map(example_data) do group
#   Dagger.spawn(group) do group
#     r = map(group) do subgroup
#       Dagger.@spawn accumulate_data(subgroup,aggregator)
#     end
#     fetch.(r)
#     #The following line is the one of question: How can I make sure that exactly the 
#     #Processors that participated in the last computation participate in this reduction and are not 
#     #scheduled to do some other work at the same time 
#     local_merge_and_flush_outputs(aggregator)
#   end
# end
# fetch(r)
# global_merge_and_flush_outputs(fetch.(map(identity,aggregator)))


# function myfunc(x)
#   all(ismissing,x) ? (0,zero(eltype(x))) : (1,mean(skipmissing(x)))
# end

# function reducefunc((n1,s1),(n2,s2))
#   (n1+n2,s1+s2)
# end
# init = ()->(0,zero(Float64))
# filters = (NoFilter(),)
# fin(x) = last(x)/first(x)
# outtypes = (Union{Float32,Missing},)
# args = ()
# kwargs = (;)
# f = create_userfunction(
#   myfunc,
#   Union{Float32,Missing},
#   red = reducefunc, 
#   init = init, 
#   finalize=fin,
#   buftype = Tuple{Int,Union{Float32,Missing}},  
# )


# optotal = GMDWop(inars, outwindows, f)





# r, = results_as_diskarrays(optotal)
# rsub = r[300:310,200:210]

outpath = tempname()
b = zzeros(Float32,size(a,2),length(stepvectime),chunks = (90,480),fill_as_missing=true,path=outpath);




# function run_op(op,outars;max_cache=1e8,threaded=true)
#   lr = DiskArrayEngine.optimize_loopranges(op,max_cache,tol_low=0.2,tol_high=0.05,max_order=2)
#   r = DiskArrayEngine.LocalRunner(optotal,lr,outars,threaded=threaded)
#   run(r)
# end

# @time run_op(optotal, (b,),threaded=true,max_cache=1e9)

# using Plots
# heatmap(b[:,:])




rmprocs(workers())
addprocs(2)
@everywhere begin
  using DiskArrayEngine, Zarr, OnlineStats
  function fit_online!(xout,x,f=identity)
    fit!(xout[],f(x))
  end
  preproc(x) = mean(skipmissing(x))
  init = ()->OnlineStats.Mean()
  fin_onine(x) = nobs(x) == 0 ? missing : OnlineStats.value(x)
end
f = create_userfunction(
    fit_online!,
    Float64,
    is_mutating = true,
    red = OnlineStats.merge!, 
    init = init, 
    finalize=fin_onine,
    buftype = Mean,  
    args = (preproc,)
)
optotal = GMDWop(inars, outwindows, f)

lr = DiskArrayEngine.optimize_loopranges(optotal,1e8,tol_low=0.2,tol_high=0.05,max_order=2)
runner = DistributedRunner(optotal, lr, (b,))
groups = DiskArrayEngine.get_procgroups(runner.op, runner.loopranges, runner.outars)
sch = DiskArrayEngine.DiskEngineScheduler(groups, runner.loopranges, runner)
DiskArrayEngine.run_group(sch)

r = runner.inbuffers_pure[2] |> fetch;

inow = (91:180,631:720,1:480)

lr = DiskArrayEngine.optimize_loopranges(optotal,3e7,tol_low=0.2,tol_high=0.05,max_order=2)

outars= (b,)


using DiskArrayEngine: get_procgroups

using Distributed
addprocs(2)

@everywhere begin

end


data = ()->[1,2,3]
p = DataPool(workers(),data)

pmap(p,1:10) do data,i
  println(i)
  sum(data)
end

using Distributed
addprocs(2)
workerpool = CachingPool([2])
push!(workerpool,3)
@everywhere function distrtest(i)
  println(i, " ", myid())
  sleep(1)
end
r = @async pmap(distrtest, workerpool, 1:100)
addprocs(2)
@everywhere function distrtest(i)
  println(i, " ", myid())
  sleep(1)
end
push!(workerpool,4)
push!(workerpool,5)





struct ReducedimsGroup{P,N}
  parent::P
  dims::NTuple{N,Int}
  is_foldl::Bool

end

using Plots
heatmap(b)


#Test for time to extract series of longitudes
cs = 100
function extract_slice(a,cs)
  r = zeros(Union{Missing,Float32},1440)
  for i in 1:cs:1440
    r[i:min(1440,i+cs-1)] .= a[i:min(1440,i+cs-1)]
  end
  r
end
csvec = [10:90;95:5:200]

readtime = [@elapsed extract_slice(a,cs) for cs in csvec]
p = plot(csvec,readtime,log="x")
ticvec = [18,20,30,36,45,60,90,120,135,150,180]
xticks!(p,ticvec)
vline!(p,ticvec)

using DiskArrays: approx_chunksize
using DiskArrayEngine: RegularWindows

singleread = median([@elapsed a[first(eachchunk(a))...] for _ in 1:10])

#p = plot(csvec,integrated_readtime.((eachchunk(a).chunks[1],),singleread,csvec))
#plot!(p,csvec,readtime)


#2 example arrays
p1 = tempname()
p2 = tempname()
a1 = zcreate(Float32,10000,10000,path = p1, chunks = (10000,1),fill_value=2.0,fill_as_missing=false)
a2 = zcreate(Float32,10000,10000,path = p2, chunks = (1,10000),fill_value=5.0,fill_as_missing=false)



eltype(r)

size(r)

rp = ProductArray((1:10000,DiskArrayEngine.RegularWindows(1,10000,step=3)))

# rangeproduct[3]
inars = (InputArray(a1,LoopWindows(rp,Val((1,2)))),InputArray(a2,LoopWindows(rp,Val((1,2)))))

outrp = ProductArray(())
outwindows = ((lw=LoopWindows(outrp,Val(())),chunks=(),ismem=false),)

f = create_userfunction(
    +,
    Float64,
    red = +, 
    init = 0.0,   
)

optotal = GMDWop(inars, outwindows, f)

DiskArrayEngine.optimize_loopranges(optotal,1e8)

compute_time(window,arraychunkspec)
compute_bufsize(window,arraychunkspec)
all_constraints(window,arraychunkspec)

using Optimization, OptimizationMOI, OptimizationOptimJL, Ipopt
using ForwardDiff, ModelingToolkit
window = [1000,1000]
loopsize = (10000,10000)


