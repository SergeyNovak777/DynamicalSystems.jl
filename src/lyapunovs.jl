export lyapunovs, lyapunov
#####################################################################################
#                                    Discrete                                       #
#####################################################################################
"""
```julia
lyapunovs(ds::DynamicalSystem, N; kwargs...) -> [λ1, λ2, ..., λD]
```
Calculate the spectrum of Lyapunov exponents [1] of `ds` by applying
a QR-decomposition on the parallelepiped matrix `N` times. Return the
spectrum sorted from maximum to minimum.

## Keyword Arguments
* `Ttr = 0` : Extra "transient" time to evolve the system before application of the
  algorithm. Should be `Int` for discrete systems.
* `dt = 1.0` : (only for continuous) Time of individual evolutions
  between successive orthonormalization steps.
* `diff_eq_kwargs = Dict()` : (only for continuous)
  Keyword arguments passed into the solvers of the
  `DifferentialEquations` package (see [`trajectory`](@ref) for more info).

## Description
The method we employ is "H2" of [2], originally stated in [3]. The vectors
defining a `D`-dimensional parallepiped are evolved using the tangent dynamics
(known also as variational equations) of the system.
A QR-decomposition at each step yields the local growth rate for each dimension
of the parallepiped. The growth rates are
then averaged over `N` successive steps, yielding the lyapunov exponent spectrum.

For discrete systems the QR-decomposition is performed at *every* step `i ∈ 1:N`.

## References

[1] : A. M. Lyapunov, *The General Problem of the Stability of Motion*,
Taylor & Francis (1992)

[2] : K. Geist *et al.*, Progr. Theor. Phys. **83**, pp 875 (1990)

[3] : G. Benettin *et al.*, Meccanica **15**, pp 9-20 & 21-30 (1980)
"""
function lyapunovs(ds::DiscreteDS, N::Real; Ttr::Real = 100)
    # Transient
    u = evolve(ds, Ttr)
    # Initialization
    D = length(u)
    eom = ds.eom
    jac = ds.jacob
    λ = zeros(eltype(u), D)
    Q = @SMatrix eye(eltype(u), D)
    K = copy(Q)
    # Main algorithm
    for i in 1:N
        u = eom(u)
        K = jac(u)*Q

        Q, R = qr(K)
        for i in 1:D
            λ[i] += log(abs(R[i, i]))
        end
    end
    λ./N
end



function lyapunovs(ds::BigDiscreteDS, N::Real; Ttr::Real = 100)
    # Transient
    u = evolve(ds, Ttr)
    # Initialization
    D = length(u)
    J = ds.J
    λ = zeros(eltype(u), D)
    Q =  eye(eltype(u), D)
    K = copy(Q)
    # Main algorithm
    for i in 1:N
        ds.dummystate .= u
        ds.eom!(u, ds.dummystate)
        ds.jacob!(J, u)
        A_mul_B!(K, J, Q)

        Q, R = qr_sq(K)
        for i in 1:D
            λ[i] += log(abs(R[i, i]))
        end
    end
    λ./N
end





"""
```julia
lyapunov(ds::DynamicalSystem, Τ, ret_conv = Val{false}; kwargs...)
```
Calculate the maximum Lyapunov exponent `λ` using a method due to Benettin [1],
which simply
evolves two neighboring trajectories (one called "given" and one called "test")
while constantly rescaling the test one.
`T`  denotes the total time of evolution (should be `Int` for discrete systems).

## Keyword Arguments

* `Ttr = 0` : Extra "transient" time to evolve the system before application of the
  algorithm. Should be `Int` for discrete systems.
* `d0 = 1e-9` : Initial & rescaling distance between the two neighboring trajectories.
* `threshold = 1e-5` : Distance threshold for rescaling.
* `diff_eq_kwargs = Dict(:abstol=>d0, :reltol=>d0)` : (only for continuous)
  Keyword arguments passed into the solvers of the
  `DifferentialEquations` package (see [`trajectory`](@ref) for more info).
* `dt = 0.1` : (only for continuous) Time of evolution between each check of
  distance exceeding the `threshold`.

* `inittest = (st1, d0) -> st1 .+ d0/sqrt(D)` :
  A function that given
  `(st1, d0)` initializes the test state with distance
  `d0` from the given state `st1` (`D` is the dimension
  of the system). This function can be used when you want to avoid
  the test state appearing in a region of the phase-space where it would have
  e.g. different energy or escape to infinity.

## Description
Two neighboring trajectories with initial distance `d0` are evolved in time.
At time ``d(t_i)`` their distance exceeds the `threshold`, which initializes
a rescaling of the test trajectory back to having distance `d0` from
the given one, while the rescaling keeps the distance vector along the maximal
expansion direction.

The maximum
Lyapunov exponent is the average of the time-local Lyapunov exponents
```math
\\lambda = \\frac{1}{t_{n}}\\sum_{i=1}^{n}
\\ln\\left( a_i \\right),\\quad a_i = \\frac{d(t_{i})}{d_0}.
```

If `ret_conv` is `Val{true}` the function returns the convergence timeseries
of the Lyapunov
exponent
`λts` as well as the corresponding time vector `ts`. If `ret_conv` is `Val{false}`
(default) the converged Lyapunov value `λts[end]` is returned instead. The number of
rescalings happened is also given, as it is equal to `length(λts)`.

## Performance Notes
For the continuous case, the algorithm becomes faster with increasing `dt`, since
integration is interrupted less frequenty. For the fastest performance you want to
fine-tune `dt, d0, threshold` such that you have the minimum amount of rescalings
*while still being well within the linearized dynamics region*.

## References
[1] : G. Benettin *et al.*, Phys. Rev. A **14**, pp 2338 (1976)
"""
function lyapunov(ds::DiscreteDS,
                  N::Int,
                  return_convergence::Type{Val{B}} = Val{false};
                  Ttr::Int = 0,
                  d0=1e-9,
                  threshold=1e-5,
                  inittest = inittest_default(dimension(ds))
                  ) where {B}

    threshold <= d0 && throw(ArgumentError("Threshold must be bigger than d0!"))

    st1 = evolve(ds, Ttr)
    st2 = inittest(st1, d0)

    if B
        λts, ts = _lyapunov_full(ds.eom, st1, st2, N, d0, threshold)
        return λts, ts
    else
        λ = _lyapunov_final(ds.eom, st1, st2, N, d0, threshold)
        return λ
    end
end

function _lyapunov_full(eom, st1, st2, N, d0, threshold)
    dist = d0
    λ = zero(eltype(st1))
    λs = eltype(st1)[]
    ts = Int[]
    i = 0
    while i < N
        #evolve until rescaling:
        while dist < threshold
            st1 = eom(st1)
            st2 = eom(st2)
            dist = norm(st1 - st2)
            i+=1
            i>=N && break
        end
        # local lyapunov exponent is simply the relative distance of the trajectories
        a = dist/d0
        λ += log(a)
        push!(λs, λ/i)
        push!(ts, i)
        i>=N && break
        #rescale:
        st2 = st1 + (st2 - st1)/a #must rescale in direction of difference
        dist = d0
    end
    return λs, ts
end

function _lyapunov_final(eom, st1, st2, N, d0, threshold)
    dist = d0
    λ = zero(eltype(st1))
    i = 0
    while i < N
        #evolve until rescaling:
        while dist < threshold
            st1 = eom(st1)
            st2 = eom(st2)
            dist = norm(st1 - st2)
            i+=1
            i>=N && break
        end
        # local lyapunov exponent is simply the relative distance of the trajectories
        a = dist/d0
        λ += log(a)
        i>=N && break
        #rescale:
        st2 = st1 + (st2 - st1)/a #must rescale in direction of difference
        dist = d0
    end
    return λ/i
end


function lyapunov(ds::BigDiscreteDS,
                  N::Int,
                  return_convergence::Type{Val{B}} = Val{false};
                  Ttr::Int = 0,
                  d0=1e-9,
                  threshold=1e-5,
                  inittest = inittest_default(dimension(ds))
                  ) where {B}

    threshold <= d0 && throw(ArgumentError("Threshold must be bigger than d0!"))

    st1 = evolve(ds, Ttr)
    st2 = inittest(st1, d0)

    if B
        λts, ts = big_lyapunov_full(ds, st1, st2, N, d0, threshold)
        return λts, ts
    else
        λ = big_lyapunov_final(ds, st1, st2, N, d0, threshold)
        return λ
    end
end

function big_lyapunov_full(ds, st1, st2, N, d0, threshold)
    dist = d0
    λ = zero(eltype(st1))
    λs = eltype(st1)[]
    ts = Int[]
    i = 0
    while i < N
        #evolve until rescaling:
        while dist < threshold
            ds.dummystate .= st1
            ds.eom!(st1, ds.dummystate)
            ds.dummystate .= st2
            ds.eom!(st2, ds.dummystate)
            ds.dummystate .= st1 .- st2
            dist = norm(ds.dummystate)
            i+=1
            i>=N && break
        end
        # local lyapunov exponent is simply the relative distance of the trajectories
        a = dist/d0
        λ += log(a)
        push!(λs, λ/i)
        push!(ts, i)
        i>=N && break
        #rescale:
        @. st2 = st1 + (st2 - st1)/a #must rescale in direction of difference
        dist = d0
    end
    return λs, ts
end

function big_lyapunov_final(ds, st1, st2, N::Int, d0::Real, threshold::Real)
    dist::eltype(st1) = d0
    λ = zero(eltype(st1))
    i = 0
    while i < N
        #evolve until rescaling:
        while dist < threshold
            ds.dummystate .= st1
            ds.eom!(st1, ds.dummystate);
            ds.dummystate .= st2
            ds.eom!(st2, ds.dummystate);
            ds.dummystate .= st1 .- st2
            dist = norm(ds.dummystate)
            i+=1
            i>=N && break
        end
        # local lyapunov exponent is simply the relative distance of the trajectories
        a = dist/d0
        λ += log(a)
        i>=N && break
        #rescale:
        @. st2 = st1 + (st2 - st1)/a #must rescale in direction of difference
        dist = d0
    end
    return λ/i
end


inittest_default(D) = (state1, d0) -> state1 .+ d0/sqrt(D)


function lyapunovs(ds::DiscreteDS1D, N::Real = 10000; Ttr::Int = 0)

    x = ds.state

    #transient system evolution
    for i in 1:Ttr
        x = ds.eom(x)
    end

    # The case for 1D systems is trivial: you add log(abs(der(x))) at each step
    λ = log(abs(ds.deriv(x)))
    for i in 1:N
        x = ds.eom(x)
        λ += log(abs(ds.deriv(x)))
    end
    λ/N
end

lyapunov(ds::DiscreteDS1D, N::Int=10000; Ttr::Int = 100) = lyapunovs(ds, N, Ttr=Ttr)





#####################################################################################
#                            Continuous Lyapunovs                                   #
#####################################################################################
function lyapunovs(ds::ContinuousDynamicalSystem, N::Real=1000;
    Ttr::Real = 0.0, diff_eq_kwargs::Dict = Dict(), dt::Real = 0.1)
    # Initialize
    tstops = dt:dt:N*dt
    D = dimension(ds)
    λ = zeros(eltype(ds.state), D)
    Q = eye(eltype(ds.state), D)
    # Transient evolution:
    if Ttr != 0
        ds = set_state(ds, evolve(ds, Ttr; diff_eq_kwargs = diff_eq_kwargs))
    end
    # Create integrator for dynamics and tangent space:
    S = [ds.state eye(eltype(ds.state), D)]
    integ = variational_integrator(
    ds, D, tstops[end], S; diff_eq_kwargs = diff_eq_kwargs)

    # Main algorithm
    for τ in tstops
        integ.u[:, 2:end] .= Q # update tangent dynamics state (super important!)
        u_modified!(integ, true)
        # Integrate
        while integ.t < τ
            step!(integ)
        end
        # Perform QR (on the tangent flow):
        Q, R = qr_sq(view(integ.u, :, 2:D+1))
        # Add correct (positive) numbers to Lyapunov spectrum
        for j in 1:D
            λ[j] += log(abs(R[j,j]))
        end
    end
    λ./(integ.t) #return spectrum
end



function lyapunov(ds::ContinuousDynamicalSystem,
                  T::Real,
                  return_convergence::Type{Val{B}} = Val{false};
                  Ttr = 0.0,
                  d0=1e-9,
                  threshold=1e-5,
                  dt = 1.0,
                  diff_eq_kwargs = Dict(:abstol=>d0, :reltol=>d0),
                  inittest = inittest_default(dimension(ds)),
                  ) where {B}

    check_tolerances(d0, diff_eq_kwargs)
    S = eltype(ds)

    T = convert(eltype(ds.state), T)
    threshold <= d0 && throw(ArgumentError("Threshold must be bigger than d0!"))

    # Transient evolution:
    if Ttr != 0
        ds = set_state(ds, evolve(ds, Ttr; diff_eq_kwargs = diff_eq_kwargs))
    end
    # Create a copy integrator with different state
    # (workaround for https://github.com/JuliaDiffEq/DiffEqBase.jl/issues/58)
    # initialize:
    st1 = copy(ds.state)
    integ1 = ODEIntegrator(ds, T; diff_eq_kwargs=diff_eq_kwargs)
    integ1.opts.advance_to_tstop=true
    ds.state .= inittest(st1, d0)
    integ2 = ODEIntegrator(ds, T; diff_eq_kwargs=diff_eq_kwargs)
    integ2.opts.advance_to_tstop=true
    ds.state .= st1

    if B
        λts::Vector{S}, ts::Vector{S} =
        lyapunov_full(integ1, integ2, T, d0, threshold, dt, diff_eq_kwargs)
        return λts, ts
    else
        λ::S =
        lyapunov_final(integ1, integ2, T, d0, threshold, dt, diff_eq_kwargs)
        return λ
    end
end

function lyapunov_full(integ1::ODEIntegrator,
                  integ2::ODEIntegrator,
                  T::Real,
                  d0=1e-9,
                  threshold=1e-5,
                  dt = 0.1,
                  diff_eq_kwargs = Dict(:abstol=>d0, :reltol=>d0),
                  )

    S = eltype(integ1.u)
    dist = d0
    λ::S = 0.0
    λ_ts::Vector{S} = [0.0]  # the traject for the Lyapunov exponent
    ts::Vector{typeof(dt)} = [0.0]    # the time points of the timeseries
    i = 0;
    tvector = dt:dt:T

    # start evolution and rescaling:
    for τ in tvector
        # evolve until rescaling:
        push!(integ1.opts.tstops, τ)
        step!(integ1)
        push!(integ2.opts.tstops, τ)
        step!(integ2)
        dist = norm(integ1.u .- integ2.u)
        # Rescale:
        if dist ≥ threshold
            # add computed scale to accumulator (scale = local lyaponov exponent):
            a = dist/d0
            λ += log(a)
            push!(λ_ts, λ/τ)
            push!(ts, τ)
            # Rescale and reset everything:
            # Must rescale towards difference direction:
            @. integ2.u = integ1.u + (integ2.u - integ1.u)/a
            u_modified!(integ2, true)
            set_proposed_dt!(integ2, integ1)
            dist = d0
        end
    end
    λ_ts, ts
end

function lyapunov_final(integ1::ODEIntegrator,
                  integ2::ODEIntegrator,
                  T::Real,
                  d0=1e-9,
                  threshold=10^5*d0,
                  dt = 0.1,
                  diff_eq_kwargs = Dict(:abstol=>d0, :reltol=>d0),
                  )

    dist = d0
    λ::eltype(integ1.u) = 0.0
    i = 0;
    tvector = dt:dt:T
    finalτ = dt

    # start evolution and rescaling:
    for τ in tvector
        # evolve until rescaling:
        push!(integ1.opts.tstops, τ)
        step!(integ1)
        push!(integ2.opts.tstops, τ)
        step!(integ2)
        dist = norm(integ1.u .- integ2.u)
        # Rescale:
        if dist ≥ threshold
            # add computed scale to accumulator (scale = local lyaponov exponent):
            a = dist/d0
            λ += log(a)
            finalτ = τ
            # Rescale and reset everything:
            # Must rescale towards difference direction:
            @. integ2.u = integ1.u + (integ2.u - integ1.u)/a
            u_modified!(integ2, true)
            set_proposed_dt!(integ2, integ1)
            dist = d0
        end
    end
    return λ/finalτ
end
