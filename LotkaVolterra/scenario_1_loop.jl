## Environment and packages
cd(@__DIR__)
using Pkg; Pkg.activate("."); Pkg.instantiate()

using OrdinaryDiffEq
using ModelingToolkit
using DataDrivenDiffEq
using LinearAlgebra, DiffEqSensitivity, Optim
using DiffEqFlux, Flux
using Plots
gr()
using JLD2, FileIO
using Statistics
# Set a random seed for reproduceable behaviour
using Random
Random.seed!(1234)


# Create a function to adapt the noise magnitude
function noisy_magnitude(iteration)
    iteration <= 40 && return Float32(1e-3)
    iteration <= 80 && return Float32(5e-3)
    iteration <= 120 && return Float32(1e-2)
    iteration <= 160 && return Float32(2.5e-2)
    return Float32(5e-2)
end

## Data generation
function lotka!(du, u, p, t)
    α, β, γ, δ = p
    du[1] = α*u[1] - β*u[2]*u[1]
    du[2] = γ*u[1]*u[2]  - δ*u[2]
end

# Define the experimental parameter
tspan = (0.0f0,3.0f0)
u0 = Float32[0.44249296,4.6280594]
p_ = Float32[1.3, 0.9, 0.8, 1.8]
prob = ODEProblem(lotka!, u0,tspan, p_)
solution = solve(prob, Vern7(), abstol=1e-12, reltol=1e-12, saveat = 0.1)

# Ideal data
X = Array(solution)
t = solution.t

# Add noise in terms of the mean
x̄ = mean(X, dims = 2)*5e-2

## Define the network
# Gaussian RBF as activation
rbf(x) = exp.(-(x.^2))

function recover_dynamics(X, t, svname, grpname)

    @info "Started run $(grpname)."

    # Define the network 2->5->5->5->2
    U = FastChain(
        FastDense(2, 5, rbf),
        FastDense(5, 5, rbf),
        FastDense(5, 5, rbf),
        FastDense(5, 2),
    )
    # Get the initial parameters
    p = initial_params(U)

    # Define the hybrid model
    function ude_dynamics!(du, u, p, t, p_true)
        û = U(u, p) # Network prediction
        du[1] = p_true[1] * u[1] + û[1]
        du[2] = -p_true[4] * u[2] + û[2]
    end

    # Closure with the known parameter
    nn_dynamics!(du, u, p, t) = ude_dynamics!(du, u, p, t, p_)
    # Define the problem
    prob_nn = ODEProblem(nn_dynamics!, X[:, 1], (t[1], t[end]), p)

    ## Function to train the network
    # Define a predictor
    function predict(θ, X = X[:, 1], T = t)
        Array(
            solve(
                prob_nn,
                Vern7(),
                u0 = X,
                p = θ,
                tspan = (T[1], T[end]),
                saveat = T,
                abstol = 1e-6,
                reltol = 1e-6,
                sensealg = ForwardDiffSensitivity(),
            ),
        )
    end

    # Simple L2 loss
    function loss(θ)
        X̂ = predict(θ)
        sum(abs2, X .- X̂) + Float32(1e-4)*sum(abs2, θ)/length(θ)
    end

    # Container to track the losses
    losses = Float32[]

    # Callback to show the loss during training
    callback(θ, l) = begin
        push!(losses, l)
        false
    end

    ## Training

    # First train with ADAM for better convergence -> move the parameters into a
    # favourable starting positing for BFGS
    res1 = DiffEqFlux.sciml_train(
        loss,
        p,
        ADAM(0.1f0),
        cb = callback,
        maxiters = 200,
    )
    println("Training loss after $(length(losses)) iterations: $(losses[end])")
    # Train with BFGS
    res2 = DiffEqFlux.sciml_train(
        loss,
        res1.minimizer,
        BFGS(initial_stepnorm = 0.01f0),
        cb = callback,
        maxiters = 10000,
    )
    println(
        "Final training loss after $(length(losses)) iterations: $(losses[end])",
    )

    p_trained = res2.minimizer

    X̂ = predict(p_trained)
    Ŷ = U(X̂, p_trained)

    # Create a Basis
    @variables u[1:2]
    # Generate the basis functions, multivariate polynomials up to deg 5
    # and sine
    b = [polynomial_basis(u, 5); sin.(u)]
    basis = Basis(b, u)


    # Create an optimizer for the SINDy problem
    opt = SR3(Float32(1e-2), Float32(0.1))
    # Create the thresholds which should be used in the search process
    λ = exp10.(-7:0.1:5)
    # Target function to choose the results from; x = L0 of coefficients and L2-Error of the model
    g(x) = x[1] < 1 ? Inf : norm(x, 2)

    # Test on uode derivative data
    Ψ = SINDy(X̂, Ŷ, basis, λ,  opt, g = g, maxiter = 50000, normalize = true, denoise = true, convergence_error = Float32(1e-10)) # Succeed

    # Extract the parameter
    p̂ = parameters(Ψ)

    # Just the equations
    b = Basis((u, p, t) -> Ψ(u, ones(Float32, length(p̂)), t), u)

    # Retune for better parameters -> we could also use DiffEqFlux or other parameter estimation tools here.
    Ψf = SINDy(
        X̂,
        Ŷ,
        b,
        STRRidge(0.01),
        maxiter = 100,
        convergence_error = 1e-18,
    ) # Succeed

    p̂ = parameters(Ψf)

    @info "Found equations : $(Ψf.equations.eqs)"
    @info "Parameter estimation : $(p̂)"

    ## Save the results

    jldopen("$(svname)recovery_loop.jld2", "a+") do file
        mygroup = JLD2.Group(file, grpname)
        mygroup["X"] = X
        mygroup["t"] = t
        mygroup["initial_parameters"] = p
        mygroup["trained_parameters"] = p_trained
        mygroup["losses"] = losses
        mygroup["result"] = Ψf
    end

    @info "Finished run $(grpname)."

    return
end

for i in 1:200
    Xₙ = X .+ (noisy_magnitude(i)*x̄) .* randn(eltype(X), size(X)...)
    recover_dynamics(Xₙ, t, "Scenario_1_broadnoise_", "$i")
end
