module DAT
export registerDATFunction, mapCube, getInAxes, getOutAxes, findAxis, reduceCube, getAxis
importall ..Cubes
importall ..CubeAPI
importall ..CubeAPI.CachedArrays
importall ..CABLABTools
importall ..Cubes.TempCubes
import ...CABLAB
import ...CABLAB.workdir
using Base.Dates
import NullableArrays.NullableArray
import NullableArrays.isnull
import StatsBase.Weights
importall CABLAB.CubeAPI.Mask
global const debugDAT=false
macro debug_print(e)
  debugDAT && return(:(println($e)))
  :()
end
#Clear Temp Folder when loading
#myid()==1 && isdir(joinpath(workdir[1],"tmp")) && rm(joinpath(workdir[1],"tmp"),recursive=true)

"""
Configuration object of a DAT process. This holds all necessary information to perform the calculations
It contains the following fields:

- `incubes::Vector{AbstractCubeData}` The input data cubes
- `outcube::AbstractCubeData` The output data cube
- `indims::Vector{Tuple}` Tuples of input axis types
- `outdims::Tuple` Tuple of output axis types
- `axlists::Vector{Vector{CubeAxis}}` Axes of the input data cubes
- `inAxes::Vector{Vector{CubeAxis}}`
- outAxes::Vector{CubeAxis}
- LoopAxes::Vector{CubeAxis}
- axlistOut::Vector{CubeAxis}
- ispar::Bool
- isMem::Vector{Bool}
- inCubesH
- outCubeH

"""
type DATConfig
  NIN           :: Int
  NOUT          :: Int
  incubes       :: Vector
  outcubes      :: Vector
  axlists       :: Vector #Of vectors
  inAxes        :: Vector #Of vectors
  broadcastAxes :: Vector #Of Vectors
  outAxes       :: Vector
  LoopAxes      :: Vector
  axlistOut     :: Vector
  ispar         :: Bool
  isMem         :: Vector{Bool}
  inCacheSizes  :: Vector #of vectors
  loopCacheSize :: Vector{Int}
  inCubesH
  outCubeH
  outfolder     :: String
  max_cache
  fu
  inmissing     :: Tuple
  outmissing    :: Tuple
  no_ocean      :: Int
  inplace      :: Bool
  genOut      :: Tuple
  finalizeOut :: Tuple
  retCubeType
  outBroadCastAxes
  addargs
  kwargs
end
function DATConfig(incubes::Tuple,inAxes,outAxes,outtype,max_cache,fu,inmissing,outmissing,no_ocean,inplace,genOut,outfolder,finalizeOut,retCubeType,outBroadCastAxes,ispar,addargs,kwargs)
  DATConfig(length(incubes),                  # NIN
  length(outAxes),                            # NOUT
  AbstractCubeData[c for c in incubes],       # incubes
  AbstractCubeData[EmptyCube{outtype[i]}() for i=1:length(outAxes)],# outcubes
  Vector{CubeAxis}[],                         # axlists
  inAxes,                                     # inAxes
  Vector{Int}[],                              # broadcastAxes
  Vector{CubeAxis}[CubeAxis[a for a in axax] for axax in outAxes], # outAxes
  CubeAxis[],                                 # LoopAxes
  Vector{CubeAxis}[],                          # axlistOut
  ispar,                                 # ispar
  Bool[isa(x,AbstractCubeMem) for x in incubes], #isMem
  Vector{Int}[],                              # inCacheSizes
  Int[],                                      # loopCacheSize
  [],                                         # inCubesH
  [],                                         # outCubesH
  outfolder,                                  # outfolder
  max_cache,                                  # max_cache
  fu,                                         # fu
  inmissing,                                  # inmissing
  outmissing,                                 # outmissing
  no_ocean,                                   # no_ocean
  inplace,                                    # inplace
  genOut,                                     # genOut
  finalizeOut,                                # finalizeOut
  collect(Any,retCubeType),                   # retCubeType
  outBroadCastAxes,                           # outBroadCastAxes
  addargs,                                    # addargs
  kwargs)                                     # kwargs
end

"""
Object to pass to InnerLoop, this condenses the most important information about the calculation into a type so that
specific code can be generated by the @generated function
"""
immutable InnerObj{NIN,NOUT,T1,T2,T3,MIN,MOUT,OC,R} end
function InnerObj(dc::DATConfig)
  T1=totuple(map(length,dc.inAxes))
  T2=totuple(map(length,dc.outAxes))
  T3=totuple(map(totuple,dc.broadcastAxes))
  MIN=dc.inmissing
  MOUT=dc.outmissing
  OC=dc.no_ocean
  R=dc.inplace
  InnerObj{dc.NIN,dc.NOUT,T1,T2,T3,MIN,MOUT,OC,R}()
end

immutable DATFunction
  indims
  outdims
  args
  outtype
  inmissing
  outmissing
  no_ocean::Int
  inplace::Bool
  genOut::Tuple{Vararg{Function}}
  finalizeOut::Tuple{Vararg{Function}}
  retCubeType
end
const regDict=Dict{Function,DATFunction}()

getOuttype(outtype::Type{Any},cdata)=isa(cdata,AbstractCubeData) ? eltype(cdata) : eltype(cdata[1])
getOuttype(outtype,cdata)=outtype
getInAxes(indims::Tuple{}, cdata::AbstractCubeData)=getInAxes((indims,),(cdata,))
getInAxes(indims::Tuple{}, cdata::Tuple)=getInAxes((indims,),cdata)
getInAxes(indims::Tuple{Vararg{DataType}},cdata)=getInAxes((indims,),cdata)
getInAxes(indims::Tuple{Vararg{Tuple{Vararg{DataType}}}},cdata::AbstractCubeData)=getInAxes(indims,(cdata,))
function getInAxes(indims::Tuple{Vararg{Tuple{Vararg{DataType}}}},cdata::Tuple)
  inAxes=Vector{CubeAxis}[]
  for (dat,dim) in zip(cdata,indims)
    ii=collect(map(a->findAxis(a,axes(dat)),dim))
    if length(ii) > 0
      push!(inAxes,axes(dat)[ii])
    else
      push!(inAxes,CubeAxis[])
    end
  end
  inAxes
end
getOutAxes(outdims,cdata,pargs)=getOutAxes((outdims,),cdata,pargs)
getOutAxes(outdims::Tuple{},cdata,pargs)=CubeAxis[]
getOutAxes(outdims::Tuple{Vararg{Tuple}},cdata,pargs)=map(i->getOutAxes(i,cdata,pargs),outdims)
getOutAxes(outdims::Tuple{Vararg{Union{DataType,CubeAxis,Function}}},cdata,pargs)=map(t->getOutAxes2(cdata,t,pargs),outdims)
function getOutAxes2(cdata::Tuple,t::DataType,pargs)
  for da in cdata
    ii = findAxis(t,axes(da))
    ii>0 && return axes(da)[ii]
  end
end
getOutAxes2(cdata::Tuple,t::Function,pargs)=t(cdata,pargs)
getOutAxes2(cdata::Tuple,t::CubeAxis,pargs)=t


mapCube(fu::Function,cdata::AbstractCubeData,addargs...;kwargs...)=mapCube(fu,(cdata,),addargs...;kwargs...)

function getReg(fuObj::DATFunction,name::Symbol,cdata,nOut)
  return getfield(fuObj,name)
end
function getReg(fu,name::Symbol,cdata,nOut)
  if     name==:outtype    return ntuple(i->Any,nOut)
  elseif name==:indims     return ntuple(i->(),length(cdata))
  elseif name==:outdims    return ntuple(i->(),nOut)
  elseif name==:inmissing  return ntuple(i->:mask,length(cdata))
  elseif name==:outmissing return ntuple(i->:mask,nOut)
  elseif name==:no_ocean   return 0
  elseif name==:inplace    return true
  elseif name==:genOut     return ntuple(i->zero,nOut)
  elseif name==:finalizeOut return ntuple(i->identity,nOut)
  elseif name==:retCubeType return Any["auto" for i=1:nOut]
  end
end

"""
    reduceCube(f::Function, cube, dim::Type{T<:CubeAxis};kwargs...)

Apply a reduction function `f` on slices of the cube `cube`. The dimension(s) are specified through `dim`, which is
either an Axis type or a tuple of axis types. Keyword arguments are passed to `mapCube` or, if unknown passed again to `f`.
It is assumed that `f` takes an array input and returns a single value.
"""
reduceCube{T<:CubeAxis}(f::Function,c::CABLAB.Cubes.AbstractCubeData,dim::Type{T};kwargs...)=reduceCube(f,c,(dim,);kwargs...)
function reduceCube(f::Function,c::CABLAB.Cubes.AbstractCubeData,dim::Tuple,no_ocean=any(i->isa(i,LonAxis) || isa(i,LatAxis),axes(c)) ? 0 : 1;kwargs...)
  if in(LatAxis,dim)
    axlist=axes(c)
    inAxes=map(i->getAxis(i,axlist),dim)
    latAxis=getAxis(LatAxis,axlist)
    sfull=map(length,inAxes)
    ssmall=map(i->isa(i,LatAxis) ? length(i) : 1,inAxes)
    wone=reshape(cosd(latAxis.values),ssmall)
    ww=zeros(sfull).+wone
    wv=Weights(reshape(ww,length(ww)))
    return mapCube(f,c,wv,indims=dim,outdims=((),),inmissing=(:nullable,),outmissing=(:nullable,),inplace=false;kwargs...)
  else
    return mapCube(f,c,indims=dim,outdims=((),),inmissing=(:nullable,),outmissing=(:nullable,),inplace=false;kwargs...)
  end
end


"""
    mapCube(fun, cube, addargs...;kwargs)

Map a given function `fun` over slices of the data cube `cube`.

### Keyword arguments

* `max_cache=1e7` maximum size of blocks that are read into memory, defaults to approx 10Mb
* `outtype::DataType` output data type of the operation
* `indims::Tuple{Tuple{Vararg{CubeAxis}}}` List of input axis types for each input data cube
* `outdims::Tuple` List of output axes, can be either an axis type that has a default constructor or an instance of a `CubeAxis`
* `inmissing::Tuple` How to treat missing values in input data for each input cube. Possible values are `:nullable` `:mask` `:nan` or a value that is inserted for missing data, defaults to `:mask`
* `outmissing` How are missing values written to the output array, possible values are `:nullable`, `:mask`, `:nan`, defaults to `:mask`
* `no_ocean` should values containing ocean data be omitted, an integer specifying the cube whose input mask is used to determine land-sea points.
* `inplace` does the function write to an output array inplace or return a single value> defaults to `true`
* `ispar` boolean to determine if parallelisation should be applied, defaults to `true` if workers are available.
* `kwargs` additional keyword arguments passed to the inner function

The first argument is always the function to be applied, the second is the input cube or
a tuple input cubes if needed. If the function to be applied is registered (either as part of CABLAB or through [registerDATFunction](@ref)),
all of the keyword arguments have reasonable defaults and don't need to be supplied. Some of the function still need additional arguments or keyword
arguments as is stated in the documentation.

If you want to call mapCube directly on an unregistered function, please have a look at [Applying custom functions](@ref) to get an idea about the usage of the
input and output dimensions etc.
"""
function mapCube(fu::Function,
    cdata::Tuple,addargs...;
    max_cache=1e7,
    fuObj=get(regDict,fu,fu),
    outdims=getReg(fuObj,:outdims,cdata,1),
    indims=getReg(fuObj,:indims,cdata,length(outdims)),
    outtype=getReg(fuObj,:outtype,cdata,length(outdims)),
    inmissing=getReg(fuObj,:inmissing,cdata,length(outdims)),
    outmissing=getReg(fuObj,:outmissing,cdata,length(outdims)),
    no_ocean=getReg(fuObj,:no_ocean,cdata,length(outdims)),
    inplace=getReg(fuObj,:inplace,cdata,length(outdims)),
    genOut=getReg(fuObj,:genOut,cdata,length(outdims)),
    outfolder=joinpath(workdir[1],string(tempname()[2:end],fu)),
    finalizeOut=getReg(fuObj,:finalizeOut,cdata,length(outdims)),
    retCubeType=getReg(fuObj,:retCubeType,cdata,length(outdims)),
    ispar=nprocs()>1,
    outBroadCastAxes=Vector{CubeAxis}[CubeAxis[] for i=1:length(outdims)],
    debug=false,
    kwargs...)
  @debug_print "Generating DATConfig"
  dc=DATConfig(cdata,
    getInAxes(indims,cdata),
    getOutAxes(outdims,cdata,addargs),
    map(i->getOuttype(i,cdata),outtype),
    max_cache,fu,inmissing,outmissing,no_ocean,inplace,genOut,outfolder,finalizeOut,retCubeType,outBroadCastAxes,ispar,addargs,kwargs)
  analyseaddargs(fuObj,dc)
  @debug_print "Reordering Cubes"
  reOrderInCubes(dc)
  @debug_print "Analysing Axes"
  analyzeAxes(dc)
  @debug_print "Calculating Cache Sizes"
  getCacheSizes(dc)
  @debug_print "Generating Output Cube"
  generateOutCubes(dc)
  @debug_print "Generating cube handles"
  getCubeHandles(dc)
  @debug_print "Running main Loop"
  debug && return(dc)
  runLoop(dc)
  @debug_print "Finalizing Output Cube"

  if dc.NOUT==1
    return dc.finalizeOut[1](dc.outcubes[1])
  else
    return ntuple(i->dc.finalizeOut[i](dc.outcubes[i]),dc.NOUT)
  end

end

function enterDebug(fu::Function,
  cdata::Tuple,addargs...;
  max_cache=1e7,
  sfu=string(fu),
  fuObj=get(regDict,sfu,sfu),
  outtype=getReg(fuObj,:outtype,cdata),
  indims=getReg(fuObj,:indims,cdata),
  outdims=getReg(fuObj,:outdims,cdata),
  inmissing=getReg(fuObj,:inmissing,cdata),
  outmissing=getReg(fuObj,:outmissing,cdata),
  no_ocean=getReg(fuObj,:no_ocean,cdata),
  inplace=getReg(fuObj,:inplace,cdata),
  genOut=getReg(fuObj,:genOut,cdata),
  finalizeOut=getReg(fuObj,:finalizeOut,cdata),
  retCubeType=getReg(fuObj,:retCubeType,cdata),
  outBroadCastAxes=CubeAxis[],
  kwargs...)
  DATConfig(cdata,getInAxes(indims,cdata),getOutAxes(outdims,cdata,addargs),getOuttype(outtype,cdata),max_cache,sfu,inmissing,outmissing,no_ocean,inplace,genOut,finalizeOut,retCubeType,outBroadCastAxes,addargs,kwargs)
end

function analyseaddargs(sfu::DATFunction,dc)
    dc.addargs=isa(sfu.args,Function) ? sfu.args(dc.incubes,dc.addargs) : dc.addargs
end
analyseaddargs(sfu::Function,dc)=nothing

function mustReorder(cdata,inAxes)
  reorder=false
  axlist=axes(cdata)
  for (i,fi) in enumerate(inAxes)
    axlist[i]==fi || return true
  end
  return false
end

function reOrderInCubes(dc::DATConfig)
  cdata=dc.incubes
  inAxes=dc.inAxes
  for i in 1:length(cdata)
    if mustReorder(cdata[i],inAxes[i])
      perm=getFrontPerm(cdata[i],inAxes[i])
      cdata[i]=permutedims(cdata[i],perm)
    end
    push!(dc.axlists,axes(cdata[i]))
  end
end

function runLoop(dc::DATConfig)
  if dc.ispar
    #TODO CHeck this for multiple output cubes, how to parallelize
    #I thnk this should work, but not 100% sure yet
    allRanges=distributeLoopRanges(dc.outcubes[1].block_size.I[(end-length(dc.LoopAxes)+1):end],map(length,dc.LoopAxes))
    pmap(r->CABLAB.DAT.innerLoop(Main.PMDATMODULE.dc.fu,CABLAB.CABLABTools.totuple(Main.PMDATMODULE.dc.inCubesH),
      Main.PMDATMODULE.dc.outCubeH,CABLAB.DAT.InnerObj(Main.PMDATMODULE.dc),r,Main.PMDATMODULE.dc.addargs,Main.PMDATMODULE.dc.kwargs),allRanges)
    @everywhereelsem for oci=1:length(dc.outcubes)
      isa(dc.outcubes[oci],TempCube) && CachedArrays.sync(dc.outCubeH[oci])
    end
  else
    innerLoop(dc.fu,totuple(dc.inCubesH),dc.outCubeH,InnerObj(dc),totuple(map(length,dc.LoopAxes)),dc.addargs,dc.kwargs)
    foreach(oci->(isa(dc.outCubeH[oci],CachedArray) && CachedArrays.sync(dc.outCubeH[oci])),1:length(dc.outcubes))
  end
  dc.outcubes
end

generateOutCubes(dc::DATConfig)=[generateOutCube(dc,dc.genOut[i],eltype(dc.outcubes[i]),i) for i=1:length(dc.outcubes)]
function generateOutCube(dc::DATConfig,gfun,T1,i)
  T=typeof(gfun(T1))
  outsize=sizeof(T)*(length(dc.axlistOut[i])>0 ? prod(map(length,dc.axlistOut[i])) : 1)
  if dc.retCubeType[i]=="auto"
    if dc.ispar || outsize>dc.max_cache
      dc.retCubeType[i]=TempCube
    else
      dc.retCubeType[i]=CubeMem
    end
  end
  if dc.retCubeType[i]<:TempCube
    dc.outcubes[i]=TempCube(dc.axlistOut[i],CartesianIndex(totuple([map(length,dc.outAxes[i]);dc.loopCacheSize])),folder=string(dc.outfolder,"_$i"),T=T,persist=false)
  elseif dc.retCubeType[i]<:CubeMem
    newsize=map(length,dc.axlistOut[i])
    outar=Array{T}(newsize...)
    @inbounds for ii in eachindex(outar)
      outar[ii]=gfun(T1)
    end
    dc.outcubes[i] = Cubes.CubeMem(dc.axlistOut[i], outar,zeros(UInt8,newsize...))
  else
    error("return cube type not defined")
  end
end

dcg=nothing
function getCubeHandles(dc::DATConfig)
  if dc.ispar
    freshworkermodule()
    global dcg=dc
      passobj(1, workers(), [:dcg],from_mod=CABLAB.DAT,to_mod=Main.PMDATMODULE)
    @everywhereelsem begin
      dc=Main.PMDATMODULE.dcg
      for ioutcube=1:length(dc.outcubes)
        if isa(dc.outcubes[ioutcube],CubeMem)
          push!(dc.outCubeH,dc.outcubes[ioutcube])
        elseif isa(dc.outcubes[ioutcube],TempCube)
          tc=openTempCube(string(dc.outfolder,"_$ioutcube"))
          push!(dc.outCubeH,CachedArray(tc,1,tc.block_size,MaskedCacheBlock{eltype(tc),length(tc.block_size.I)}))
        else
          error("Output cube type unknown")
        end
      end
      for icube=1:dc.NIN
        if dc.isMem[icube]
          push!(dc.inCubesH,dc.incubes[icube])
        else
          push!(dc.inCubesH,CachedArray(dc.incubes[icube],1,CartesianIndex(totuple(dc.inCacheSizes[icube])),MaskedCacheBlock{eltype(dc.incubes[icube]),length(dc.axlists[icube])}))
        end
      end
    end
  else
    # For one-processor operations
    for icube=1:dc.NIN
      if dc.isMem[icube]
        push!(dc.inCubesH,dc.incubes[icube])
      else
        push!(dc.inCubesH,CachedArray(dc.incubes[icube],1,CartesianIndex(totuple(dc.inCacheSizes[icube])),MaskedCacheBlock{eltype(dc.incubes[icube]),length(dc.axlists[icube])}))
      end
    end
    for ioutcube=1:length(dc.outcubes)
      if isa(dc.outcubes[ioutcube],TempCube)
        push!(dc.outCubeH,CachedArray(dc.outcubes[ioutcube],1,dc.outcubes[ioutcube].block_size,MaskedCacheBlock{eltype(dc.outcubes[ioutcube]),length(dc.axlistOut[ioutcube])}))
      elseif isa(dc.outcubes[ioutcube],CubeMem)
        push!(dc.outCubeH,dc.outcubes[ioutcube])
      else
        error("Output cube type unknown")
      end
    end
  end
end

function init_DATworkers()
  freshworkermodule()
end

function analyzeAxes(dc::DATConfig)
  #First check if one of the axes is a concrete type
  for icube=1:dc.NIN
    for a in dc.axlists[icube]
      in(a,dc.inAxes[icube]) || in(a,dc.LoopAxes) || push!(dc.LoopAxes,a)
    end
  end
  #Try to construct outdims
  for ioutcube=1:length(dc.outAxes)
    outnotfound=find([!isdefined(dc.outAxes[ioutcube],ii) for ii in eachindex(dc.outAxes[ioutcube])])
    for ii in outnotfound
      dc.outAxes[ioutcube][ii]=dc.outdims[ioutcube][ii]()
    end
  end
  length(dc.LoopAxes)==length(unique(map(typeof,dc.LoopAxes))) || error("Make sure that cube axes of different cubes match")
  for icube=1:dc.NIN
    push!(dc.broadcastAxes,Int[])
    for iLoopAx=1:length(dc.LoopAxes)
      !in(typeof(dc.LoopAxes[iLoopAx]),map(typeof,dc.axlists[icube])) && push!(dc.broadcastAxes[icube],iLoopAx)
    end
  end
  #Add output broadcast axes
  for ioutcube=1:length(dc.outAxes)
    push!(dc.broadcastAxes,Int[])
    LoopAxes2=CubeAxis[]
    for iLoopAx=1:length(dc.LoopAxes)
      if typeof(dc.LoopAxes[iLoopAx]) in dc.outBroadCastAxes[ioutcube]
        push!(dc.broadcastAxes[end],iLoopAx)
      else
        push!(LoopAxes2,dc.LoopAxes[iLoopAx])
      end
    end
    push!(dc.axlistOut,CubeAxis[dc.outAxes[ioutcube];LoopAxes2])
  end
  return dc
end

function getCacheSizes(dc::DATConfig)

  if all(dc.isMem)
    dc.inCacheSizes=[Int[] for i=1:dc.NIN]
    dc.loopCacheSize=Int[length(x) for x in dc.LoopAxes]
    return dc
  end
  inAxlengths      = [Int[length(dc.inAxes[i][j]) for j=1:length(dc.inAxes[i])] for i=1:length(dc.inAxes)]
  inblocksizes     = map((x,T)->prod(x)*sizeof(eltype(T)),inAxlengths,dc.incubes)
  inblocksize,imax = findmax(inblocksizes)
  outblocksizes    = map((A,C)->length(A)>0 ? sizeof(eltype(C))*prod(map(length,A)) : 1,dc.outAxes,dc.outcubes)
  outblocksize     = length(outblocksizes) > 0 ? findmax(outblocksizes)[1] : 1
  loopCacheSize    = getLoopCacheSize(max(inblocksize,outblocksize),dc.LoopAxes,dc.max_cache)
  @debug_print "Choosing Cache Size of $loopCacheSize"
  for icube=1:dc.NIN
    if dc.isMem[icube]
      push!(dc.inCacheSizes,Int[])
    else
      push!(dc.inCacheSizes,map(length,dc.inAxes[icube]))
      for iLoopAx=1:length(dc.LoopAxes)
        in(typeof(dc.LoopAxes[iLoopAx]),map(typeof,dc.axlists[icube])) && push!(dc.inCacheSizes[icube],loopCacheSize[iLoopAx])
      end
    end
  end
  dc.loopCacheSize=loopCacheSize
  return dc
end

"Calculate optimal Cache size to DAT operation"
function getLoopCacheSize(preblocksize,LoopAxes,max_cache)
  totcachesize=max_cache

  incfac=totcachesize/preblocksize
  incfac<1 && error("Not enough memory, please increase availabale cache size")
  loopCacheSize = ones(Int,length(LoopAxes))
  for iLoopAx=1:length(LoopAxes)
    s=length(LoopAxes[iLoopAx])
    if s<incfac
      loopCacheSize[iLoopAx]=s
      incfac=incfac/s
      continue
    else
      ii=floor(Int,incfac)
      while ii>1 && rem(s,ii)!=0
        ii=ii-1
      end
      loopCacheSize[iLoopAx]=ii
      break
    end
  end
  return loopCacheSize
end

using Base.Cartesian
@generated function distributeLoopRanges{N}(block_size::NTuple{N,Int},loopR::Vector)
    quote
        @assert length(loopR)==N
        nsplit=Int[div(l,b) for (l,b) in zip(loopR,block_size)]
        baseR=UnitRange{Int}[1:b for b in block_size]
        a=Array(NTuple{$N,UnitRange{Int}},nsplit...)
        @nloops $N i a begin
            rr=@ntuple $N d->baseR[d]+(i_d-1)*block_size[d]
            @nref($N,a,i)=rr
        end
        a=reshape(a,length(a))
    end
end

using Base.Cartesian
@generated function innerLoop{T1,T2,T3,T4,NIN,NOUT,M1,M2,OC,R}(f,xin,xout,::InnerObj{NIN,NOUT,T1,T2,T4,M1,M2,OC,R},loopRanges::T3,addargs,kwargs)
  NinCol      = T1
  NoutCol     = T2
  broadcastvars = T4
  inmissing     = M1
  outmissing    = M2
  Nloopvars   = length(T3.parameters)
  loopRangesE = Expr(:block)
  subIn=[NinCol[i] > 0 ? Expr(:call,:(getSubRange2),:(xin[$i]),fill(:(:),NinCol[i])...) : Expr(:call,:(CABLAB.CubeAPI.CachedArrays.getSingVal),:(xin[$i])) for i=1:NIN]
  subOut=[Expr(:call,:(getSubRange2),:(xout[$i]),fill(:(:),NoutCol[i])...) for i=1:NOUT]
  sub1=copy(subOut)
  printex=Expr(:call,:println,:outstream)
  for i=Nloopvars:-1:1
    isym=Symbol("i_$(i)")
    push!(printex.args,string(isym),"=",isym," ")
  end
  for i=1:Nloopvars
    isym=Symbol("i_$(i)")
    for j=1:NIN
      in(i,broadcastvars[j]) || push!(subIn[j].args,isym)
    end
    for j=1:NOUT
      in(i,broadcastvars[NIN+j]) || push!(subOut[j].args,isym)
    end
    if T3.parameters[i]==UnitRange{Int}
      unshift!(loopRangesE.args,:($isym=loopRanges[$i]))
    elseif T3.parameters[i]==Int
      unshift!(loopRangesE.args,:($isym=1:loopRanges[$i]))
    else
      error("Wrong Range argument")
    end
  end
  sub2=copy(subOut)
  foreach(asub->push!(asub.args,Expr(:kw,:write,true)),subOut)
  loopBody=Expr(:block,[:(($(Symbol("aout_$i")),$(Symbol("mout_$i"))) = $(subOut[i])) for i=1:NOUT]...)
  sub3=copy(subOut)
  callargs=Any[:f,Expr(:parameters,Expr(:...,:kwargs))]
  if R
    for j=1:NOUT
      push!(callargs,Symbol("aout_$j"))
      outmissing[j]==:mask && push!(callargs,Symbol("mout_$j"))
    end
  end
  for j=1:NOUT
    outmissing[j]==:nullable && push!(loopBody.args,:($(Symbol("aout_$j"))=toNullableArray($(Symbol("aout_$j")),$(Symbol("mout_$j")))))
  end
  for (i,s) in enumerate(subIn)
    ains=Symbol("ain_$i");mins=Symbol("min_$i")
    push!(loopBody.args,:(($(ains),$(mins))=$s))
    push!(callargs,ains)
    if isa(inmissing[i],Symbol)
      if inmissing[i]==:mask
        push!(callargs,mins)
      elseif inmissing[i]==:nan
        push!(loopBody.args,:(fillVals($(ains),$(mins),NaN)))
      elseif inmissing[i]==:nullable
        push!(loopBody.args,:($(ains)=toNullableArray($(ains),$(mins))))
      end
    else
      push!(loopBody.args,:(fillVals($(ains),$(mins),$(inmissing))))
    end
  end
  if OC>0
    ocex=quote
      if ($(Symbol(string("min_",OC)))[1] & OCEAN) == OCEAN
          $(Expr(:block,[:($(Symbol(string("mout_",j)))[:]=OCEAN) for j=1:NOUT]...))
          continue
      end
    end
    push!(loopBody.args,ocex)
  end
  push!(callargs,Expr(:...,:addargs))
  if R
    push!(loopBody.args,Expr(:call,callargs...))
  else
    if outmissing==:mask
      push!(loopBody.args,quote
        ao,mo=$(Expr(:call,callargs...))
        aout_1[1]=ao
        mout_1[1]=mo
      end)
    else
      push!(loopBody.args,:(aout_1[1]=$(Expr(:call,callargs...))))
    end
  end
  for j=1:NOUT
    if outmissing[j]==:nan
      push!(loopBody.args, :(fillNanMask($(Symbol("aout_$j")),$(Symbol("mout_$j")))))
    elseif outmissing[j]==:nullable
      push!(loopBody.args, :(fillNullableArrayMask($(Symbol("aout_$j")),$(Symbol("mout_$j")))))
    end
  end
  loopEx = length(loopRangesE.args)==0 ? loopBody : Expr(:for,loopRangesE,loopBody)
  if debugDAT
    b=IOBuffer()
    show(b,loopEx)
    s=takebuf_string(b)
    loopEx=quote
      println($s)
      $loopEx
    end
  end
  return loopEx
end

"This function sets the values of x to NaN if the mask is missing"
function fillVals(x::AbstractArray,m::AbstractArray{UInt8},v)
  nmiss=0
  @inbounds for i in eachindex(x)
    if (m[i] & 0x01)==0x01
      x[i]=v
      nmiss+=1
    end
  end
  return nmiss==length(x) ? true : false
end
fillVals(x,::Void,v)=nothing
"Sets the mask to missing if values are NaN"
function fillNanMask(x,m)
  for i in eachindex(x)
    m[i]=isnan(x[i]) ? 0x01 : 0x00
  end
end
fillNanMask(m)=m[:]=0x01
#"Converts data and Mask to a NullableArray"
toNullableArray(x,m)=NullableArray(x,reinterpret(Bool,m))
function fillNullableArrayMask(x,m)
  for i in eachindex(x.values)
    m[i]=isnull(x[i]) ? 0x01 : 0x00
  end
end

"""
    registerDATFunction(f, dimsin, [dimsout, [addargs]]; inmissing=(:mask,...), outmissing=:mask, no_ocean=0)

Registers a function so that it can be applied to the whole data cube through mapCube.

  - `f` the function to register
  - `dimsin` a tuple containing the Axes Types that the function is supposed to work on. If multiple input cubes are needed, then a tuple of tuples must be provided
  - `dimsout` a tuple of output Axes types. If omitted, it is assumed that the output is a single value. Can also be a function with the signature (cube,pargs)-> ... which returns the output Axis. This is useful if the output axis can only be constructed based on runtime input.
  - `addargs` an optional function with the signature (cube,pargs)-> ... , to calculate function arguments that are passed to f which are only known when the function is called. Here `cube` is a tuple of input cubes provided when `mapCube` is called and `pargs` is a list of trailing arguments passed to `mapCube`. For example `(cube,pargs)->(length(getAxis(cube[1],"TimeAxis")),pargs[1])` would pass the length of the time axis and the first trailing argument of the mapCube call to each invocation of `f`
  - `inmissing` tuple of symbols, determines how to deal with missing data for each input cube. `:mask` means that masks are explicitly passed to the function call, `:nan` replaces all missing data with NaNs, and `:nullable` passes a NullableArray to `f`
  - `outmissing` symbol, determines how missing values is the output are interpreted. Same values as for `inmissing are allowed`
  - `no_ocean` integer, if set to a value > 0, omit function calls that would act on grid cells where the first value in the mask is set to `OCEAN`.
  - `inplace::Bool` defaults to true. If `f` returns a single value, instead of writing into an output array, one can set `inplace=false`.

"""
function registerDATFunction(f,dimsin::Tuple{Vararg{Tuple}},dimsout::Tuple{Vararg{Tuple}},addargs...;outtype=Any,inmissing=ntuple(i->:mask,length(dimsin)),outmissing=:mask,no_ocean=0,inplace=true,genOut=zero,finalizeOut=identity,retCubeType="auto")
    nIn=length(dimsin)
    nOut=length(dimsout)
    inmissing=expandTuple(inmissing,nIn)
    outmissing=expandTuple(outmissing,nOut)
    outtype=expandTuple(outtype,nOut)
    genOut=expandTuple(genOut,nOut)
    finalizeOut=expandTuple(finalizeOut,nOut)
    retCubeType=expandTuple(retCubeType,nOut)
    if length(addargs)==1 && isa(addargs[1],Function)
      addargs=addargs[1]
    end
    regDict[f]=DATFunction(dimsin,dimsout,addargs,outtype,inmissing,outmissing,no_ocean,inplace,genOut,finalizeOut,retCubeType)
end
function registerDATFunction(f,dimsin,dimsout,addargs...;kwargs...)
  dimsin=expandTuple(dimsin,1)
  dimsout=expandTuple(dimsout,1)
  isempty(dimsin) ? (dimsin=((),)) : isa(dimsin[1],Tuple) || (dimsin=(dimsin,))
  isempty(dimsout) ? (dimsout=((),)) : isa(dimsout[1],Tuple) || (dimsout=(dimsout,))
  registerDATFunction(f,dimsin,dimsout,addargs...;kwargs...)
end
function registerDATFunction(f,dimsin;kwargs...)
  registerDATFunction(f,dimsin,();kwargs...)
end
expandTuple(x,nin)=ntuple(i->x,nin)
expandTuple(x::Tuple,nin)=x

function getAxis{T<:CubeAxis}(a::Type{T},v)
  for i=1:length(v)
      isa(v[i],a) && return v[i]
  end
  return 0
end

function getAxis{T<:CubeAxis}(a::Type{T},cube::AbstractCubeData,)
  for ax in axes(cube)
      isa(ax,a) && return ax
  end
  error("Axis $a not found in $(axes(cube))")
end


"Calculate an axis permutation that brings the wanted dimensions to the front"
function getFrontPerm{T}(dc::AbstractCubeData{T},dims)
  ax=axes(dc)
  N=length(ax)
  perm=Int[i for i=1:length(ax)];
  iold=Int[]
  for i=1:length(dims) push!(iold,findin(ax,[dims[i];])[1]) end
  iold2=sort(iold,rev=true)
  for i=1:length(iold) splice!(perm,iold2[i]) end
  perm=Int[iold;perm]
  return ntuple(i->perm[i],N)
end

end
