# AbstractVector wrapper around PETSc Vec types
export Vec, comm, NullVec

 """
  Construct a high level Vec object from a low level C.Vec.
  The data field is used to protect things from GC.
  A finalizer is attached to deallocate the memory of the underlying C.Vec, unless 
  `first_instance` is set to true.
  `assembled` indicates when values are set via `setindex!` and is reset by
   `AssemblyEnd`
   `verify_assembled` when true, calls to `isassembled` verify all processes
   have `assembled` = true, when false, only the local assembly state is 
   checked.  This essentially makes the user responsible for assembling 
  the vector before passing it into functions that will use it (like KSP
  solves, etc.).

"""
type Vec{T,VType} <: AbstractVector{T}
  p::C.Vec{T}
  assembled::Bool # whether are all values have been assembled
  verify_assembled::Bool # check whether all processes are assembled
  insertmode::C.InsertMode # current mode for setindex!
  data::Any # keep a reference to anything needed for the Mat
            # -- needed if the Mat is a wrapper around a Julia object,
            #    to prevent the object from being garbage collected.
  function Vec(p::C.Vec{T}, data=nothing; first_instance::Bool=true, 
               verify_assembled::Bool=true)
    v = new(p, false, verify_assembled, C.INSERT_VALUES, data)
    if first_instance
      chk(C.VecSetType(p, VType))  # set the type here to ensure it matches VType
      finalizer(v, PetscDestroy)
    end
    return v
  end
end

import Base: show, showcompact, writemime
function show(io::IO, x::Vec)

  myrank = MPI.Comm_rank(comm(x))
  if myrank == 0
    println("Petsc Vec of lenth ", length(x))
  end
  if isassembled(x)
    println(io, "Process ", myrank, " entries:")
    x_arr = LocalArrayRead(x)
    show(io, x_arr)
    LocalArrayRestore(x_arr)
  else
    println(io, "Process ", myrank, " not assembled")
  end
end


showcompact(io::IO, x::Vec) = show(io, x)
writemime(io::IO, ::MIME"text/plain", x::Vec) = show(io, x)

"""
  Null vectors, used in place of void pointers in the C
  API
"""
global const NullVec = Dict{DataType, Vec}()


if have_petsc[1]
  global const NullVec1 = Vec{Float64, C.VECSTANDARD}(C.Vec{Float64}(C_NULL), first_instance=false)
  NullVec[Float64] = NullVec1
end
if have_petsc[2]
  global const NullVec2 = Vec{Float32, C.VECSTANDARD}(C.Vec{Float32}(C_NULL), first_instance=false)
  NullVec[Float32] = NullVec2
end
if have_petsc[3]
  global const NullVec3 = Vec{Complex128, C.VECSTANDARD}(C.Vec{Complex128}(C_NULL), first_instance=false)
  NullVec[Complex128] = NullVec3

end
 """
  Gets the MPI communicator of a vector.
"""
function comm{T}(v::Vec{T})
  rcomm = Ref{MPI.CComm}()
  ccomm = C.PetscObjectComm(T, v.p.pobj)
  fcomm = convert(MPI.Comm, ccomm)
  return fcomm
end


export gettype

 """
  Get the symbol that is the format of the vector
"""
gettype{T,VT}(a::Vec{T,VT}) = VT


 """
  Create an empty, unsized vector.
"""
function Vec{T}(::Type{T}, vtype::C.VecType=C.VECMPI;
                comm::MPI.Comm=MPI.COMM_WORLD)
  p = Ref{C.Vec{T}}()
  chk(C.VecCreate(comm, p))
  v = Vec{T, vtype}(p[])
  v
end

 """
  Create a vector, specifying the (global) length len or the local length
  mlocal.  Even if the blocksize is > 1, teh lengths are always number of 
  elements in the vector, not number of block elements.  Thus
  len % blocksize must = 0.
"""
function Vec{T<:Scalar}(::Type{T}, len::Integer=C.PETSC_DECIDE;
                         vtype::C.VecType=C.VECMPI,  bs=1,
                         comm::MPI.Comm=MPI.COMM_WORLD, 
                         mlocal::Integer=C.PETSC_DECIDE)
  vec = Vec(T, vtype; comm=comm)
  resize!(vec, len, mlocal=mlocal)
  set_block_size(vec, bs)
  vec
end

 """
  Make a PETSc vector out of an array.  If used in parallel, the array becomes
  the local part of the PETSc vector
"""
# make a Vec that is a wrapper around v, where v stores the local data
function Vec{T<:Scalar}(v::Vector{T}; comm::MPI.Comm=MPI.COMM_WORLD)
  p = Ref{C.Vec{T}}()
  chk(C.VecCreateMPIWithArray(comm, 1, length(v), C.PETSC_DECIDE, v, p))
  pv = Vec{T, C.VECMPI}(p[], v)
  return pv
end

function set_block_size{T<:Scalar}(v::Vec{T}, bs::Integer)
  chk(C.VecSetBlockSize(v.p, bs))
end

function get_blocksize{T<:Scalar}(v::Vec{T})
  bs = Ref{PetscInt}()
  chk(C.VecGetBlockSize(v.p, bs))
  return Int(bs[])
end

export VecGhost, VecLocal, restore


 """
  Make a PETSc vector with space for ghost values.  ghost_idx are the 
  global indices that will be copied into the ghost space.
"""
# making mlocal the position and mglobal the keyword argument is inconsistent
# with the other Vec constructors, but it makes more sense here
function VecGhost{T<:Scalar, I <: Integer}(::Type{T}, mlocal::Integer, 
                  ghost_idx::Array{I,1}; comm=MPI.COMM_WORLD, m=C.PETSC_DECIDE, bs=1)

    nghost = length(ghost_idx)
    ghost_idx2 = [ PetscInt(i -1) for i in ghost_idx]

    vref = Ref{C.Vec{T}}()
    if bs == 1
      chk(C.VecCreateGhost(comm, mlocal, m, nghost, ghost_idx2, vref))
    elseif bs > 1
      chk(C.VecCreateGhostBlock(comm, bs, mlocal, mlocal, m, nghost, ghost_idx2, vref))
    else
      println(STDERR, "WARNING: unsupported block size requested, bs = ", bs)
    end

    return Vec{T, C.VECMPI}(vref[])
end

 """
  Create a VECSEQ that contains both the local and the ghost values of the 
  original vector.  The underlying memory for the orignal and output vectors
  alias.
"""
function VecLocal{T <:Scalar}( v::Vec{T, C.VECMPI})

  vref = Ref{C.Vec{T}}()
  chk(C.VecGhostGetLocalForm(v.p, vref))
  # store v to use with Get/Restore LocalForm
  # Petsc reference counting solves the gc problem
  return Vec{T, C.VECSEQ}(vref[], v)
end

#TODO: use restore for all types of restoring a local view
 """
  Tell Petsc the VecLocal is no longer needed
"""
function restore{T}(v::Vec{T, C.VECSEQ})

  vp = v.data
  vref = Ref(v.p)
  chk(C.VecGhostRestoreLocalForm(vp.p, vref))
end


 """
  The Petsc function to deallocate Vec objects
"""
function PetscDestroy{T}(vec::Vec{T})
  if !PetscFinalized(T)  && !isfinalized(vec)
    C.VecDestroy(Ref(vec.p))
    vec.p = C.Vec{T}(C_NULL)  # indicate the vector is finalized
  end
end

 """
  Determine whether a vector has already been finalized
"""
function isfinalized(vec::Vec)
  return isfinalized(vec.p)
end

function isfinalized(vec::C.Vec)
  return vec.pobj == C_NULL
end

global const is_nullvec = isfinalized  # another name for doing the same check

 """
  Use the PETSc routine for printing a vector to stdout
"""
function petscview{T}(vec::Vec{T})
  viewer = C.PetscViewer{T}(C_NULL)
  chk(C.VecView(vec.p, viewer))
end

function Base.resize!(x::Vec, m::Integer=C.PETSC_DECIDE; mlocal::Integer=C.PETSC_DECIDE)
  if m == mlocal == C.PETSC_DECIDE
    throw(ArgumentError("either the length (m) or local length (mlocal) must be specified"))
  end

  chk(C.VecSetSizes(x.p, mlocal, m))
  x
end

###############################################################################
export ghost_begin!, ghost_end!, scatter!, ghost_update!
# ghost vectors: essential methods
 """
  Start communication to update the ghost values (on other processes) from the local
  values
"""
function ghost_begin!{T<:Scalar}(v::Vec{T, C.VECMPI}; imode=C.INSERT_VALUES,
                               smode=C.SCATTER_FORWARD)
    chk(C.VecGhostUpdateBegin(v.p, imode, smode))
    return v
end

 """
  Finish communication for updating ghost values
"""
function ghost_end!{T<:Scalar}(v::Vec{T, C.VECMPI}; imode=C.INSERT_VALUES,
                               smode=C.SCATTER_FORWARD)
    chk(C.VecGhostUpdateEnd(v.p, imode, smode))
    return v
end

# ghost vectors: helpful methods
 """
  Convenience method for calling both ghost_begin! and ghost_end!
"""
function scatter!{T<:Scalar}(v::Vec{T, C.VECMPI}; imode=C.INSERT_VALUES, smode=C.SCATTER_FORWARD)

  ghost_begin!(v, imode=imode, smode=smode)
  ghost_end!(v, imode=imode, smode=smode)
end

# is there a way to specify all varargs must be same type?
# this can't be named scatter! because of ambiguity with the index set scatter!
 """
  Convenience method for calling ghost_begin! and ghost_end! for multiple vectors
"""
function ghost_update!(v...; imode=C.INSERT_VALUES, smode=C.SCATTER_FORWARD)

  for i in v
    ghost_begin!(i, imode=imode, smode=smode)
  end

  for i in v
    ghost_end!(i, imode=imode, smode=smode)
  end

  return v
end



###############################################################################
export lengthlocal, sizelocal, localpart

Base.convert(::Type{C.Vec}, v::Vec) = v.p

import Base.length
 """
  Get the global length of the vector
"""
function length(x::Vec)
  sz = Ref{PetscInt}()
  chk(C.VecGetSize(x.p, sz))
  Int(sz[])
end

 """
  Get the global size of the vector
"""
Base.size(x::Vec) = (length(x),)

 """
  Get the length of the local portion of the vector
"""
function lengthlocal(x::Vec)
  sz = Ref{PetscInt}()
  chk(C.VecGetLocalSize(x.p, sz))
  sz[]
end

"""
  Get the local size of the vector
"""
sizelocal(x::Vec) = (lengthlocal(x),)

"""
  Get local size of the vector
"""
sizelocal{T,n}(t::AbstractArray{T,n}, d) = (d>n ? 1 : sizelocal(t)[d])

 """
  Get the range of global indices that define the local part of the vector.
  Internally, this calls the Petsc function VecGetOwnershipRange, and has
  the same limitations as that function, namely that some vector formats do 
  not have a well defined contiguous range.
"""
function localpart(v::Vec)
  # this function returns a range from the first to the last indicies (1 based)
  # this is different than the Petsc VecGetOwnershipRange function where
  # the max value is one more than the number of entries
  low = Ref{PetscInt}()
  high = Ref{PetscInt}()
  chk(C.VecGetOwnershipRange(v.p, low, high))
  return (low[]+1):(high[])
end

"""
  Similar to localpart, but returns the range of block indices
"""
function localpart_block(v::Vec)
  low = Ref{PetscInt}()
  high = Ref{PetscInt}()
  chk(C.VecGetOwnershipRange(v.p, low, high))
  bs = get_blocksize(v)
  low_b = div(low[], bs); high_b = div(high[]-1, bs)
  ret = (low_b+1):(high_b+1)

  return ret
end


function Base.similar{T,VType}(x::Vec{T,VType})
  p = Ref{C.Vec{T}}()
  chk(C.VecDuplicate(x.p, p))
  Vec{T,VType}(p[])
end

Base.similar{T}(x::Vec{T}, ::Type{T}) = similar(x)
Base.similar{T,VType}(x::Vec{T,VType}, T2::Type) =
  Vec(T2, length(x), VType; comm=comm(x), mlocal=lengthlocal(x))

function Base.similar{T,VType}(x::Vec{T,VType}, T2::Type, len::Union{Int,Dims})
  length(len) == 1 || throw(ArgumentError("expecting 1-dimensional size"))
  len[1]==length(x) && T2==T ? similar(x) : Vec(T2, len[1], vtype=VType; comm=comm(x))
end

function Base.similar{T,VType}(x::Vec{T,VType}, len::Union{Int,Dims})
  length(len) == 1 || throw(ArgumentError("expecting 1-dimensional size"))
  len[1]==length(x) ? similar(x) : Vec(T, len[1], vtype=VType; comm=comm(x))
end

function Base.copy(x::Vec)
  AssemblyBegin(x)
  y = similar(x)
  AssemblyEnd(x)
  chk(C.VecCopy(x.p, y.p))
  y
end

###############################################################################
export localIS, local_to_global_mapping, set_local_to_global_mapping, has_local_to_global_mapping

"""
  Constructs index set mapping from local indexing to global indexing, based 
  on localpart()
"""
function localIS{T}(A::Vec{T})

  rows = localpart(A)
  rowis = IS(T, rows, comm=comm(A))
  return rowis
end

"""
  Like localIS, but returns a block index IS
"""
function localIS_block{T}(A::Vec{T})
  rows = localpart_block(A)
  bs = get_blocksize(A)
  rowis = ISBlock(T, bs, rows, comm=comm(A))
#  set_blocksize(rowis, get_blocksize(A))
  return rowis
end
"""
  Construct ISLocalToGlobalMappings for the vector.  If a block vector, 
  create a block index set
"""
function local_to_global_mapping(A::Vec)

  # localIS creates strided index sets, which require only constant
  # memory
  if get_blocksize(A) == 1
    rowis = localIS(A)
  else 
    rowis = localIS_block(A)
  end
  row_ltog = ISLocalToGlobalMapping(rowis)

  return row_ltog
end

# need a better name
"""
  Registers the ISLocalToGlobalMapping with the Vec
"""
function set_local_to_global_mapping{T}(A::Vec{T}, rmap::ISLocalToGlobalMapping{T})

  chk(C.VecSetLocalToGlobalMapping(A.p, rmap.p))
end

"""
  Check if the local to global mapping has been registered
"""
function has_local_to_global_mapping{T}(A::Vec{T})

  rmap_ref = Ref{C.ISLocalToGlobalMapping{T}}()
  chk(C.VecGetLocalToGlobalMapping(A.p, rmap_re))

  rmap = rmap_ref[]
  
  return rmap.pobj != C_NULL
end


##########################################################################
import Base: setindex!
export assemble, isassembled, AssemblyBegin, AssemblyEnd

# for efficient vector assembly, put all calls to x[...] = ... inside
# assemble(x) do ... end
 """
  Start communication to assemble stashed values into the vector

  The MatAssemblyType is not needed for vectors, but is provided for 
  compatability with the Mat case.

  Unless vec.verify_assembled == false, users must *never* call the 
  C functions VecAssemblyBegin, VecAssemblyEnd and VecSetValues, they must
  call AssemblyBegin, AssemblyEnd, and setindex!.
"""
function AssemblyBegin(x::Vec, t::C.MatAssemblyType=C.MAT_FINAL_ASSEMBLY)
  chk(C.VecAssemblyBegin(x.p))
end

"""
  Generic fallback for AbstractArray, no-op
"""
function AssemblyBegin(x::AbstractArray, t::C.MatAssemblyType=C.MAT_FINAL_ASSEMBLY)

end
 """
  Finish communication for assembling the vector
"""
function AssemblyEnd(x::Vec, t::C.MatAssemblyType=C.MAT_FINAL_ASSEMBLY)
  chk(C.VecAssemblyEnd(x.p))
  x.assembled = true
end

"""
  Check if a vector is assembled (ie. does not have stashed values).  If 
  `x.verify_assembled`, the assembly state of all processes is checked, 
  otherwise only the local process is checked. `local_only` forces only 
  the local process to be checked, regardless of `x.verify_assembled`.
"""
function isassembled(x::Vec, local_only=false)
  myrank = MPI.Comm_rank(comm(x))
  if x.verify_assembled && !local_only
    val = MPI.Allreduce(Int8(x.assembled), MPI.LAND, comm(x))
  else
    val = x.assembled
  end

  return Bool(val)
end

"""
  Generic fallback for AbstractArray, no-op
"""
function AssemblyEnd(x::AbstractArray, t::C.MatAssemblyType=C.MAT_FINAL_ASSEMBLY)

end

isassemble(x::AbstractArray) = true
# assemble(f::Function, x::Vec) is defined in mat.jl

 """
  Like setindex, but requires the indices be 0-base
"""
function setindex0!{T}(x::Vec{T}, v::Array{T}, i::Array{PetscInt})
  n = length(v)
  if n != length(i)
    throw(ArgumentError("length(values) != length(indices)"))
  end
  #    println("  in setindex0, passed bounds check")
  chk(C.VecSetValues(x.p, n, i, v, x.insertmode))
  x.assembled = false
  x
end

function setindex!{T}(x::Vec{T}, v::Number, i::Integer)
  # can't call VecSetValue since that is a static inline function
  setindex0!(x, T[ v ], PetscInt[ i - 1 ])
  v
end

# set multiple entries to a single value
setindex!{T<:Integer}(x::Vec, v::Number, I::AbstractArray{T}) = assemble(x) do
  for i in I
    x[i] = v
  end
  x
end

function Base.fill!{T}(x::Vec{T}, v::Number)
  chk(C.VecSet(x.p, T(v)))
  return x
end

function setindex!{T<:Integer}(x::Vec, v::Number, I::Range{T})
  if abs(step(I)) == 1 && minimum(I) == 1 && maximum(I) == length(x)
    fill!(x, v)
    return v
  else
    # use invoke here to avoid a recursion loop
    return invoke(setindex!, (Vec,typeof(v),AbstractVector{T}), x,v,I)
  end
end

#TODO: make this a single call to VecSetValues
setindex!{T<:Real}(x::Vec, V::AbstractArray, I::AbstractArray{T}) =
assemble(x) do
  if length(V) != length(I)
    throw(ArgumentError("length(values) != length(indices)"))
  end
  # possibly faster to make a PetscScalar array from V, and
  # a copy of the I array shifted by 1, to call setindex0! instead?
  c = 1
  for i in I
    x[i] = V[c]
    c += 1
  end
  x
end

# logical indexing
setindex!(A::Vec, x::Number, I::AbstractArray{Bool}) = assemble(A) do
  for i = 1:length(I)
    if I[i]
      A[i] = x
    end
  end
  A
end
for T in (:(Array{T2}),:(AbstractArray{T2})) # avoid method ambiguities
  @eval setindex!{T2<:Scalar}(A::Vec, X::$T, I::AbstractArray{Bool}) = assemble(A) do
    c = 1
    for i = 1:length(I)
      if I[i]
        A[i] = X[c]
        c += 1
      end
    end
    A
  end
end

##########################################################################
import Base.getindex

# like getindex but for 0-based indices i
function getindex0{T}(x::Vec{T}, i::Vector{PetscInt})
  v = similar(i, T)
  chk(C.VecGetValues(x.p, length(i), i, v))
  v
end

getindex(x::Vec, i::Integer) = getindex0(x, PetscInt[i-1])[1]

getindex(x::Vec, I::AbstractVector{PetscInt}) =
  getindex0(x, PetscInt[ (i-1) for i in I ])

##########################################################################
# more indexing
# 0-based (to avoid temporary copies)
export set_values!, set_values_blocked!, set_values_local!, set_values_blocked_local!

function set_values!{T <: Scalar}(x::Vec{T}, idxs::DenseArray{PetscInt}, 
                                 vals::DenseArray{T}, o::C.InsertMode=x.insertmode)

  chk(C.VecSetValues(x.p, length(idxs), idxs, vals, o))
end

function set_values!{T <: Scalar, I <: Integer}(x::Vec{T}, idxs::DenseArray{I},
                                         vals::DenseArray{T}, o::C.InsertMode=x.insertmode)

  # convert idxs to PetscInt
  p_idxs = PetscInt[ i for i in idxs]
  set_values!(x, p_idxs, vals, o)
end

function set_values!(x::AbstractVector, idxs::AbstractArray, vals::AbstractArray,
                     o::C.InsertMode=C.INSERT_VALUES)

  if o == C.INSERT_VALUES
    for i=1:length(idxs)
      x[idxs[i] + 1] = vals[i]
    end
  elseif o == C.ADD_VALUES
    for i=1:length(idxs)
      x[idxs[i] + 1] += vals[i]
    end
  else
    throw(ArgumentError("Unsupported InsertMode"))
  end
end


function set_values_blocked!{T <: Scalar}(x::Vec{T}, idxs::DenseArray{PetscInt},
                                          vals::DenseArray{T}, o::C.InsertMode=x.insertmode)

  chk(C.VecSetValuesBlocked(x.p, length(idxs), idxs, vals, o))
end

function set_values_blocked!{T <: Scalar, I <: Integer}(x::Vec{T}, 
                             idxs::DenseArray{I}, vals::DenseArray{T}, 
                             o::C.InsertMode=x.insertmode)
 
  p_idxs = PetscInt[ i for i in idxs]
  set_values_blocked!(x, p_idxs, vals, o)
end

# julia doesn't have blocked vectors, so skip


function set_values_local!{T <: Scalar}(x::Vec{T}, idxs::DenseArray{PetscInt},
                                       vals::DenseArray{T}, o::C.InsertMode=x.insertmode)

  chk(C.VecSetValuesLocal(x.p, length(idxs), idxs, vals, o))
end

function set_values_local!{T <: Scalar, I <: Integer}(x::Vec{T}, 
                           idxs::DenseArray{I}, vals::DenseArray{T}, 
                           o::C.InsertMode=x.insertmode)

  p_idxs = PetscInt[ i for i in idxs]
  set_values_local!(x, p_idxs, vals, o)
end

# for julia vectors, local = global
function set_values_local!(x::AbstractArray, idxs::AbstractArray, 
                           vals::AbstractArray, o::C.InsertMode=C.INSERT_VALUES)

  if o == C.INSERT_VALUES
    for i=1:length(idxs)
      x[idxs[i] + 1] = vals[i]
    end
  elseif o == C.ADD_VALUES
    for i=1:length(idxs)
      x[idxs[i] + 1] += vals[i]
    end
  else
    throw(ArgumentError("Unsupported InsertMode"))
  end

end


function set_values_blocked_local!{T <: Scalar}(x::Vec{T}, 
                                   idxs::DenseArray{PetscInt},
                                   vals::DenseArray{T}, o::C.InsertMode=x.insertmode)

  chk(C.VecSetValuesBlockedLocal(x.p, length(idxs), idxs, vals, o))
end


function set_values_blocked_local!{T <: Scalar, I <: Integer}(x::Vec{T}, 
                           idxs::DenseArray{I}, vals::DenseArray{T}, 
                           o::C.InsertMode=x.insertmode)

  p_idxs = PetscInt[ i for i in idxs]
  set_values_blocked_local!(x, p_idxs, vals, o)
end

# julia doesn't have blocked vectors, so skip





                             

###############################################################################
import Base: abs, exp, log, conj, conj!
export abs!, exp!, log!
for (f,pf) in ((:abs,:VecAbs), (:exp,:VecExp), (:log,:VecLog),
  (:conj,:VecConjugate))
  fb = symbol(string(f, "!"))
  @eval begin
    function $fb(x::Vec)
      chk(C.$pf(x.p))
      x
    end
    $f(x::Vec) = $fb(copy(x))
  end
end

export chop!
function chop!(x::Vec, tol::Real)
  chk(C.VecChop(x.p, tol))
#  chk(ccall((:VecChop, petsc), PetscErrorCode, (pVec, PetscReal), x, tol))
  x
end

for (f, pf, sf) in ((:findmax, :VecMax, :maximum), (:findmin, :VecMin, :minimum))
  @eval begin
    function Base.$f{T<:Real}(x::Vec{T})
      i = Ref{PetscInt}()
      v = Ref{T}()
      chk(C.$pf(x.p, i, v))
      (v[], i[]+1)
    end
    Base.$sf{T<:Real}(x::Vec{T}) = $f(x)[1]
  end
end
# For complex numbers, VecMax and VecMin apparently return the max/min
# real parts, which doesn't match Julia's maximum/minimum semantics.

function Base.norm{T<:Real}(x::Union{Vec{T},Vec{Complex{T}}}, p::Number)
  v = Ref{T}()
  n = p == 1 ? C.NORM_1 : p == 2 ? C.NORM_2 : p == Inf ? C.NORM_INFINITY :
  throw(ArgumentError("unrecognized Petsc norm $p"))
  chk(C.VecNorm(x.p, n, v))
  v[]
end

if VERSION >= v"0.5.0-dev+8353" # JuliaLang/julia#13681
  import Base.normalize!
else
  export normalize!
end

 """
  computes v = norm(x,2), divides x by v, and returns v
"""
function normalize!{T<:Real}(x::Union{Vec{T},Vec{Complex{T}}})
  v = Ref{T}()
  chk(C.VecNormalize(x.p, v))
  v[]
end

function Base.dot{T}(x::Vec{T}, y::Vec{T})
  d = Ref{T}()
  chk(C.VecDot(y.p, x.p, d))
  return d[]
end

# unconjugated dot product (called for x'*y)
function Base.At_mul_B{T<:Complex}(x::Vec{T}, y::Vec{T})
  d = Array(T, 1)
  chk(C.VecTDot(x.p, y.p, d))
  return d
end

# pointwise operations on pairs of vectors (TODO: support in-place variants?)
import Base: max, min, .*, ./, .\
for (f,pf) in ((:max,:VecPointwiseMax), (:min,:VecPointwiseMin),
  (:.*,:VecPointwiseMult), (:./,:VecPointwiseDivide))
  @eval function ($f)(x::Vec, y::Vec)
    w = similar(x)
    chk(C.$pf(w.p, x.p, y.p))
    w
  end
end

import Base: +, -
function Base.scale!{T}(x::Vec{T}, s::Number)
  chk(C.VecScale(x.p, T(s)))
  x
end
Base.scale{T}(x::Vec{T},s::Number) = scale!(copy(x),s)
(.*)(x::Vec, a::Number...) = scale(x, prod(a))
(.*)(a::Number, x::Vec) = scale(x, a)
(./)(x::Vec, a::Number) = scale(x, inv(a))
(.\)(a::Number, x::Vec) = scale(x, inv(a))
function (./)(a::Number, x::Vec)
  y = copy(x)
  chk(C.VecReciprocal(y.p))
  if a != 1.0
    scale!(y, a)
  end
  y
end

function (+){T<:Scalar}(x::Vec{T}, a::Number...)
  y = copy(x)
  chk(C.VecShift(y.p, T(sum(a))))
  return y
end
(+){T<:Scalar}(a::Number, x::Vec{T}) = x + a
(-){T<:Scalar}(x::Vec{T}, a::Number) = x + (-a)
(-)(x::Vec) = scale(x, -1)
function (-){T<:Scalar}(a::Number, x::Vec{T})
  y = -x
  chk(C.VecShift(y.p, T(a)))
  return y
end

import Base: ==
function (==)(x::Vec, y::Vec)
  b = Ref{PetscBool}()
  chk(C.VecEqual(x.p, y.p, b))
  b[] != 0
end

function (==)(x::Vec, y::AbstractArray)
  flag = true
  x_arr = LocalVector(x) 
  for i=1:length(x_arr)  # do localpart, then MPI reduce
    flag = flag && x_arr[i] == y[i]
  end
  restore(x_arr)

  buf = Int8[flag]
  # process 0 is root
  recbuf = MPI.Reduce(buf, 1, MPI.LAND, 0, comm(x))

  if  MPI.Comm_rank(comm(x)) == 0
    buf[1] = recbuf[1]
  end

  MPI.Bcast!(buf, 1, 0, comm(x))
 
  return convert(Bool, buf[1]) 
end

function Base.sum{T}(x::Vec{T})
  s = Ref{T}()
  chk(C.VecSum(x.p, s))
  s[]
end

###############################################################################
# map and friends
import Base: map!, map
#map() should be inherited from base

function map!(f, c)
  map!(f, c, c)
end

"""
Applys f element-wise to src to populate dest.  If src is a ghost vector,
then f is applied to the ghost elements as well as the local elements.
"""
function map!{T}(f, dest::Vec{T}, src::Vec)
  if length(dest) < length(src)
    throw(ArgumentError("Length of dest must be >= src"))
  end
  if localpart(dest)[1] != localpart(src)[1]
    throw(ArgumentError("start of local part of src and dest must be aligned"))
  end

  dest_arr = LocalArray(dest)
  src_arr = LocalArrayRead(src)
  try
    for (idx, val) in enumerate(src)
      dest[idx] = f(val)
    end
  finally
    LocalArrayRestore(dest_arr)
    LocalArrayRestore(src_arr)
  end
end

"""
  Multiple source vector map.  All vectors must have the local and global 
  lengths.  If some a ghost vectors and some are not, the map is applied
  only to the local part
"""
function map!{T, T2}(f, dest::Vec{T}, src1::Vec{T}, src2::Vec{T2},  src_rest::Vec{T2}...)

  # annoying workaround for #13651
  srcs = (src1, src2, src_rest...)
  # check lengths
  dest_localrange = localpart(dest)
  dest_len = length(dest)
  for src in srcs
    srclen = length(src)
    srcrange_local = localpart(src)
    if dest_len < srclen
      throw(ArgumentError("Length of destination must be greater than source"))
    end

    if dest_localrange[1] != srcrange_local[1]
      throw(ArgumentError("start of local part of src and dest must be aligned"))
    end
  end
  
  # extract the arrays
  n = length(srcs)
  len = 0
  len_prev = 0
  src_arrs = Array(LocalArrayRead{T2}, n)
  use_length_local = false

  dest_arr = LocalArray(dest)
  try 
    for (idx, src) in enumerate(srcs)
      src_arrs[idx] = LocalArrayRead(src)

      # check of length of arrays are same or not
      len = length(src_arrs[idx])
      if len != len_prev && idx != 1 && !use_length_local
        use_length_local = true
      end
      len_prev = len
    end

    # if not all same, do only the local part (which must be the same for all)
    if use_length_local
      min_length = lenth(src1)
    else
      min_length = length(src_arrs[1])
    end
      # do the map
      vals = Array(T, n)
      for i=1:min_length  # TODO: make this the minimum array length
        for j=1:n  # extract values
          vals[j] = src_arrs[j][i]
        end
        dest_arr[i] = f(vals...)
      end
  finally # restore the arrays
    for src_arr in src_arrs
      LocalArrayRestore(src_arr)
    end
    LocalArrayRestore(dest_arr)
  end
end

##########################################################################
export axpy!, aypx!, axpby!, axpbypcz!
import Base.LinAlg.BLAS.axpy!

# y <- alpha*x + y
function axpy!{T}(alpha::Number, x::Vec{T}, y::Vec{T})
  chk(C.VecAXPY(y.p, T(alpha), x.p))
  y
end
# w <- alpha*x + y
function axpy!{T}(alpha::Number, x::Vec{T}, y::Vec{T}, w::Vec{T})
  chk(C.VecWAXPY(w.p, T(alpha), x.p, y.p))
  y
end
# y <- alpha*y + x
function aypx!{T}(x::Vec{T}, alpha::Number, y::Vec{T})
  chk(C.VecAYPX( y.p, T(alpha), x.p))
  y
end
# y <- alpha*x + beta*y
function axpby!{T}(alpha::Number, x::Vec{T}, beta::Number, y::Vec{T})
  chk(C.VecAXPBY(y.p, T(alpha), T(beta), x.p))
  y
end
# z <- alpha*x + beta*y + gamma*z
function axpbypcz!{T}(alpha::Number, x::Vec{T}, beta::Number, y::Vec{T},
  gamma::Number, z::Vec{T})
  chk(C.VecAXPBYPCZ(z.p, T(alpha), T(beta), T(gamma), x.p, y.p))
  z
end

# y <- y + \sum_i alpha[i] * x[i]
function axpy!{V<:Vec}(y::V, alpha::AbstractArray, x::AbstractArray{V})
  n = length(x)
  length(alpha) == n || throw(BoundsError())
  _x = [X.p for X in x]
  _alpha = eltype(y)[a for a in alpha]
  C.VecMAXPY(y.p, n, _alpha, _x)
  y
end

##########################################################################
# element-wise vector operations:
import Base: .*, ./, .^, +, -

for (f,pf) in ((:.*,:VecPointwiseMult), (:./,:VecPointwiseDivide), (:.^,:VecPow))
  @eval function ($f)(x::Vec, y::Vec)
    z = similar(x)
    chk(C.$pf(z.p, x.p, y.p))
    return z
  end
end

for (f,s) in ((:+,1), (:-,-1))
  @eval function ($f){T}(x::Vec{T}, y::Vec{T})
    z = similar(x)
    chk(C.VecWAXPY(z.p, T($s), y.p, x.p))
    return z
  end
end


##############################################################################
export LocalVector, LocalVector_readonly, restore

 """
  Object representing the local part of the array, accessing the memory directly.
  Supports all the same indexing as a regular Array
"""
type LocalVector{T <: Scalar, ReadOnly} <: DenseArray{T, 1}
  a::Array{T, 1}  # the array object constructed around the pointer
  ref::Ref{Ptr{T}}  # reference to the pointer to the data
  pobj::C.Vec{T}
  isfinalized::Bool  # has this been finalized yet
  function LocalVector(a::Array, ref::Ref, ptr)
    varr = new(a, ref, ptr, false)
    # backup finalizer, shouldn't ever be used because users must call
    # restore before their changes will take effect
    finalizer(varr, restore)
    return varr
  end

end


typealias LocalVectorRead{T} LocalVector{T, true}
typealias LocalVectorWrite{T} LocalVector{T, false}
"""
  Get the LocalArray of a vector.  Users must call LocalArrayRestore when
  finished updating the vector
"""
function LocalVector{T}(vec::Vec{T})

  len = lengthlocal(vec)

  ref = Ref{Ptr{T}}()
  chk(C.VecGetArray(vec.p, ref))
  a = pointer_to_array(ref[], len)
  return LocalVector{T, false}(a, ref, vec.p)
end

"""
  Tell Petsc the LocalArray is no longer being used
"""
function restore{T}(varr::LocalVectorWrite{T})

  if !varr.isfinalized && !PetscFinalized(T) && !isfinalized(varr.pobj)
    ptr = varr.ref
    chk(C.VecRestoreArray(varr.pobj, ptr))
  end 
  varr.isfinalized = true
end

"""
  Get read-only access to the memory underlying a Petsc vector
"""
type LocalArrayRead{T <: Scalar} <: DenseArray{T, 1}
  a::Array{T, 1}  # the array object constructed around the pointer
  ref::Ref{Ptr{T}}  # reference to the pointer to the data
  pobj::C.Vec{T}
  isfinalized::Bool  # has this been finalized yet
  function LocalArrayRead(a::Array, ref::Ref, ptr)
    varr = new(a, ref, ptr, false)
    # backup finalizer, shouldn't ever be used because users must call
    # LocalArrayRestore before their changes will take effect
    finalizer(varr, LocalArrayRestore)
    return varr
  end

end

"""
  Get the LocalArrayRead of a vector.  Users must call LocalArrayRestore when 
  finished with the object.
"""
function LocalVector_readonly{T}(vec::Vec{T})

  len = lengthlocal(vec)

  ref = Ref{Ptr{T}}()
  chk(C.VecGetArrayRead(vec.p, ref))
  a = pointer_to_array(ref[], len)
  return LocalVector{T, true}(a, ref, vec.p)
end

function restore{T}(varr::LocalVectorRead{T})

  if !varr.isfinalized && !PetscFinalized(T) && !isfinalized(varr.pobj)
    ptr = [varr.ref[]]
    chk(C.VecRestoreArrayRead(varr.pobj, ptr))
  end 
  varr.isfinalized = true
end

"""
  Typealias for both kinds of LocalArrays
"""

Base.size(varr::LocalVector) = size(varr.a)
# indexing
getindex(varr::LocalVector, i) = getindex(varr.a, i)
setindex!(varr::LocalVectorWrite, v, i) = setindex!(varr.a, v, i)
Base.unsafe_convert{T}(::Type{Ptr{T}}, a::LocalVector{T}) = Base.unsafe_convert(Ptr{T}, a.a)
Base.stride(a::LocalVector, d::Integer) = stride(a.a, d)
Base.similar(a::LocalVector, T=eltype(a), dims=size(a)) = similar(a.a, T, dims)

function (==)(x::LocalVector, y::AbstractArray)
  return x.a == y
end
