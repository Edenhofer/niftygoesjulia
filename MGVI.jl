import IterativeSolvers: cg
import Random: randn
import ForwardDiff
import FFTW: plan_r2r, DHT
import Base: *
using ForwardDiff
using Zygote
using LinearAlgebra
using LinearMaps
using Statistics: mean
using Plots

using Optim

VecOrNum = Union{Number,Vector{<:Number}}

struct NegLogLikelihoodWithMetric{T<:Union{AbstractMatrix,LinearMap}}
	nll::F where F<:Function
	metric::T
	jac_at::F where F<:Function
end

struct StandardHamiltonian{T}
	nll_plus_prior::F where F<:Function
	nll_with_metric::NegLogLikelihoodWithMetric{T}
end

mutable struct Energy{
	T,
	L<:Union{Nothing,Vector{T}},
	N<:Union{Nothing,AbstractMatrix,LinearMap}
}
	potential::F where F<:Function
	position::T
	samples::L
	curvature::N
end

function to_dual_at(ξ::V) where V<:VecOrNum
	return function to_dual(δ::V)
		return map((v, p) -> ForwardDiff.Dual(v, p...), ξ, δ)
	end
end

function jacobian(f::F, ξ::V) where {F<:Function, V<:VecOrNum}
	to_dual = to_dual_at(ξ)
	jvp(δ::V) = mapreduce(ForwardDiff.partials, vcat, f(to_dual(δ)))

	function vjp(δ::T) where T<:VecOrNum
		return first(Zygote.pullback(f, ξ)[2](δ))
	end

	return LinearMap{eltype(ξ)}(jvp, vjp, first(size(ξ)))
end

function covariance_sample(cov_inv::T, jac::N, metric::M) where {
	T<:Union{AbstractMatrix,LinearMap{E}},
	N<:Union{AbstractMatrix,LinearMap{E}},
	M<:Union{AbstractMatrix,LinearMap{E}}
} where E
	ξ_new::Vector{E} = randn(first(size(cov_inv)))
	d_new::Vector{E} = jac * ξ_new .+ sqrt(inv(metric)) * randn(dims)
	j_new::Vector{E} = adjoint(jac) * metric * d_new
	m_new::Vector{E} = cg(cov_inv, j_new, log=true)[1]
	return ξ_new .- m_new
end

function gaussian_energy(noise_cov::T, data::V, signal_response::F) where {
	T<:Union{AbstractMatrix,LinearMap{E}},
	V<:AbstractVector{E},
	F<:Function
} where E
	inv_noise_cov = inv(noise_cov)
	function nll(ξ::L) where L<:VecOrNum
		res = data .- signal_response(ξ)
		return 0.5 * transpose(res) * inv_noise_cov * res
	end
	function jac_at(ξ::L) where L<:VecOrNum
		return jacobian(signal_response, ξ)
	end

	return NegLogLikelihoodWithMetric(nll, inv_noise_cov, jac_at)
end

function standard_hamiltonian(nll_w_metric::NegLogLikelihoodWithMetric{T}) where T
	function nll_plus_pr(ξ::L) where L<:VecOrNum
		return nll_w_metric.nll(ξ) + 0.5 * (ξ ⋅ ξ)
	end
	return StandardHamiltonian(nll_plus_pr, nll_w_metric)
end

function metric_gaussian_kl(
	standard_ham::StandardHamiltonian{T},
	pos::P,
	n_samples::C;
	mirror_samples::Bool=false
) where {T, P, C<:Int}
	jac = standard_ham.nll_with_metric.jac_at(pos)
	metric = standard_ham.nll_with_metric.metric
	fisher = adjoint(jac) * metric * jac + I

	samples = [covariance_sample(fisher, jac, metric) for i = 1 : n_samples]
	# TODO: convert samples to an iteration that can be mirrored
	samples = mirror_samples ? vcat(samples, -samples) : samples

	ham = standard_ham.nll_plus_prior
	kl(ξ::P) = reduce(+, ham(ξ + s) for s in samples) / length(samples)

	# Take the metric of the KL itself as curvature
	nll_fisher_by_s = mapreduce(+, samples) do s
		jac_s = standard_ham.nll_with_metric.jac_at(pos + s)
		return adjoint(jac_s) * metric * jac_s
	end
	avg_fisher = nll_fisher_by_s / length(samples) + I

	return Energy(kl, pos, samples, avg_fisher)
end

function maximum_posterior(standard_ham::StandardHamiltonian, pos::P) where P
	return Energy(standard_ham.nll_plus_prior, pos, nothing, nothing)
end

function minimize!(energy::Energy{P}; nat_grad_steps=15, nat_grad_scl=1) where P
	for _ in 1 : nat_grad_steps
		grad = first(gradient(energy.potential, energy.position))
		Δξ = cg(energy.curvature, grad, log=true)[1]
		energy.position .-= nat_grad_scl * Δξ
	end
	return energy
end

function minimize!(energy::Energy{P,Nothing,Nothing}) where P
	function ∂pot!(ξ_storage::P, ξ::P)
		ξ_storage .= first(gradient(energy.potential, ξ))
	end

	opt = optimize(energy.potential, ∂pot!, energy.position, LBFGS())
	energy.position .= Optim.minimizer(opt)
	return energy
end


dims = (1024)
k = [i < dims / 2 ? i :  dims-i for i = 0:dims-1]

# Define the harmonic transform operator as a matrix-like object
ht = plan_r2r(zeros(dims), DHT)
# Unfortunately neither Zygote nor ForwardDiff support planned Hartley
# transformations. While Zygote does not support AbstractFFTs.ScaledPlan,
# ForwardDiff does not overload the appropriate methods from AbstractFFTs.
# TODO: Push those changes to upstream. At the very least, Zygote is open to it
function *(trafo::typeof(ht), u::Vector{ForwardDiff.Dual{T,V,P}}) where {T,V,P}
	# Unpack AoS -> SoA
	vs = ForwardDiff.value.(u)
	ps = mapreduce(ForwardDiff.partials, vcat, u)
	# Actual computation
	val = trafo * vs
	jvp = trafo * ps
	# Pack SoA -> AoS (depending on jvp, might need `eachrow`)
	return map((v, p) -> ForwardDiff.Dual{T}(v, p...), val, jvp)
end
Zygote.@adjoint function *(trafo::typeof(inv(ht)), xs::T) where T
	return trafo * xs, Δ -> (nothing, trafo * Δ)
end
Zygote.@adjoint function inv(trafo::typeof(ht))
	inv_t = inv(trafo)
	return inv_t, function (Δ)
		adj_inv_t = adjoint(inv_t)
		return (- adj_inv_t * Δ * adj_inv_t, )
	end
end

# ξ := latent variables
ξ_truth = randn(dims)
conf = Dict{String,VecOrNum}("loglogavgslope_mean"=>2., "loglogavgslope_stddev"=>0.5)

loglogslope = conf["loglogavgslope_stddev"] .* randn() .+ conf["loglogavgslope_mean"]
P = @. 50 / (k^loglogslope + 1)
function correlated_field(ξ::V) where V<:VecOrNum
	return inv(ht) * (P .* ξ)
end
function signal(ξ::V) where V<:VecOrNum
	return exp.(correlated_field(ξ))
end

N = Diagonal(0.01^2 * ones(dims))
R = ones(dims)
#R[100:200] .= 0
R = Diagonal(R)

function signal_response(ξ::V) where V<:VecOrNum
	return R * signal(ξ)
end

# Generate synthetic signal and data
ss = signal(ξ_truth)
d = R * ss .+ R * sqrt(N) * randn(dims)
plot(ss, color=:red, label="ground truth", linewidt=5)
plot!(d, seriestype=:scatter, marker=:x, color=:black)

# Negative log-likelihood assuming a Gaussian energy
ge = gaussian_energy(N, d, signal_response)
ham = standard_hamiltonian(ge)

init_pos = 0.1 * randn(dims)

pos = deepcopy(init_pos)
# Maximum a Posteriori
maxap = maximum_posterior(ham, pos)
minimize!(maxap)
plot!(signal(maxap.position), label="MAP", color=:blue)

pos = deepcopy(init_pos)
n_samples = 3
# Metric Gaussian Variational Inference
mgkl = metric_gaussian_kl(ham, pos, n_samples; mirror_samples=true)
minimize!(mgkl; nat_grad_scl=1e-1)
for i in 1 : 3
	global mgkl
	println("Sampling...")
	mgkl = metric_gaussian_kl(ham, mgkl.position, n_samples; mirror_samples=true)
	println("Minimizing...")
	minimize!(mgkl; nat_grad_scl=.5)
end

for (i, s) in enumerate(mgkl.samples)
	plot!(signal(pos + s), label="Post. Sample " * string(i), color=:gray)
end
plot!(signal(mgkl.position), label="Post. Mean", color=:orange)
savefig("mgvi_example.pdf")
