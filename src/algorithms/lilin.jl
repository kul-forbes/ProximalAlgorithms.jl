# Li, Lin, "Accelerated Proximal Gradient Methods for Nonconvex Programming",
# Proceedings of NIPS 2015 (2015).

using Base.Iterators
using ProximalAlgorithms.IterationTools
using ProximalOperators: Zero
using LinearAlgebra
using Printf

"""
    LiLinIteration(; <keyword-arguments>)

Instantiate the nonconvex accelerated proximal gradient method by Li and Lin
(see Algorithm 2 in [1]) for solving optimization problems of the form

    minimize f(Ax) + g(x),

where `f` is smooth and `A` is a linear mapping (for example, a matrix).

# Arguments
- `x0`: initial point.
- `f=Zero()`: smooth objective term.
- `A=I`: linear operator (e.g. a matrix).
- `g=Zero()`: proximable objective term.
- `Lf=nothing`: Lipschitz constant of the gradient of x ↦ f(Ax).
- `gamma=nothing`: stepsize to use, defaults to `1/Lf` if not set (but `Lf` is).

# References
- [1] Li, Lin, "Accelerated Proximal Gradient Methods for Nonconvex Programming",
Proceedings of NIPS 2015 (2015).
"""

Base.@kwdef struct LiLinIteration{R,C<:Union{R,Complex{R}},Tx<:AbstractArray{C},Tf,TA,Tg}
    f::Tf = Zero()
    A::TA = I
    g::Tg = Zero()
    x0::Tx
    Lf::Maybe{R} = nothing
    gamma::Maybe{R} = Lf === nothing ? nothing : (1 / Lf)
    adaptive::Bool = false
    delta::R = real(eltype(x0))(1e-3)
    eta::R = real(eltype(x0))(0.8)
end

Base.IteratorSize(::Type{<:LiLinIteration}) = Base.IsInfinite()

mutable struct LiLinState{R<:Real,Tx,TAx}
    x::Tx             # iterate
    y::Tx             # extrapolated point
    Ay::TAx           # A times y
    f_Ay::R           # value of smooth term at y
    grad_f_Ay::TAx    # gradient of f at Ay
    At_grad_f_Ay::Tx  # gradient of smooth term at y
    # TODO: *two* gammas should be used in general, one for y and one for x
    gamma::R          # stepsize parameter of forward and backward steps
    y_forward::Tx     # forward point at y
    z::Tx             # forward-backward point
    g_z::R            # value of nonsmooth term at z
    res::Tx           # fixed-point-residual (at y)
    theta::R          # auxiliary sequence to compute extrapolated points
    F_average::R      # moving average of objective values
    q::R              # auxiliary sequence to compute moving average
end

function Base.iterate(iter::LiLinIteration{R}) where {R}
    y = copy(iter.x0)
    Ay = iter.A * y
    grad_f_Ay, f_Ay = gradient(iter.f, Ay)

    # TODO: initialize gamma if not provided
    # TODO: authors suggest Barzilai-Borwein rule?
    # TODO: *two* gammas should be used in general, one for y and one for x

    # compute initial forward-backward step
    At_grad_f_Ay = iter.A' * grad_f_Ay
    y_forward = y - iter.gamma .* At_grad_f_Ay
    z, g_z = prox(iter.g, y_forward, iter.gamma)

    Fy = f_Ay + iter.g(y)

    @assert isfinite(Fy) "initial point must be feasible"

    # compute initial fixed-point residual
    res = y - z

    state = LiLinState(
        copy(iter.x0), y, Ay, f_Ay, grad_f_Ay, At_grad_f_Ay, iter.gamma,
        y_forward, z, g_z, res, R(1), Fy, R(1),
    )

    return state, state
end

function Base.iterate(
    iter::LiLinIteration{R},
    state::LiLinState{R,Tx,TAx},
) where {R,Tx,TAx}
    # TODO: backtrack gamma at y

    Fz = iter.f(state.z) + state.g_z

    theta1 = (R(1) + sqrt(R(1) + 4 * state.theta^2)) / R(2)

    if Fz <= state.F_average - iter.delta * norm(state.res)^2
        case = 1
    else
        # TODO: re-use available space in state?
        # TODO: backtrack gamma at x
        Ax = iter.A * state.x
        grad_f_Ax, f_Ax = gradient(iter.f, Ax)
        At_grad_f_Ax = iter.A' * grad_f_Ax
        x_forward = state.x - state.gamma .* At_grad_f_Ax
        v, g_v = prox(iter.g, x_forward, state.gamma)
        Fv = iter.f(v) + g_v
        case = Fz <= Fv ? 1 : 2
    end

    if case == 1
        state.y .= state.z .+ ((state.theta - R(1)) / theta1) .* (state.z .- state.x)
        state.x, state.z = state.z, state.x
        Fx = Fz
    elseif case == 2
        state.y .=
            state.z .+ (state.theta / theta1) .* (state.z .- v) .+
            ((state.theta - R(1)) / theta1) .* (v .- state.x)
        state.x = v
        Fx = Fv
    end

    mul!(state.Ay, iter.A, state.y)
    state.f_Ay = gradient!(state.grad_f_Ay, iter.f, state.Ay)
    mul!(state.At_grad_f_Ay, adjoint(iter.A), state.grad_f_Ay)
    state.y_forward .= state.y .- state.gamma .* state.At_grad_f_Ay
    state.g_z = prox!(state.z, iter.g, state.y_forward, state.gamma)

    state.res .= state.y - state.z

    state.theta = theta1

    # NOTE: the following can be simplified
    q1 = iter.eta * state.q + 1
    state.F_average = (iter.eta * state.q * state.F_average + Fx) / q1
    state.q = q1

    return state, state
end

# Solver

struct LiLin{R, K}
    maxit::Int
    tol::R
    verbose::Bool
    freq::Int
    kwargs::K
end

function (solver::LiLin)(x0; kwargs...)
    stop(state::LiLinState) = norm(state.res, Inf) / state.gamma <= solver.tol
    disp((it, state)) =
        @printf("%5d | %.3e | %.3e\n", it, state.gamma, norm(state.res, Inf) / state.gamma)
    iter = LiLinIteration(; x0=x0, solver.kwargs..., kwargs...)
    iter = take(halt(iter, stop), solver.maxit)
    iter = enumerate(iter)
    if solver.verbose
        iter = tee(sample(iter, solver.freq), disp)
    end
    num_iters, state_final = loop(iter)
    return state_final.z, num_iters
end

LiLin(; maxit=10_000, tol=1e-8, verbose=false, freq=100, kwargs...) = 
    LiLin(maxit, tol, verbose, freq, kwargs)
