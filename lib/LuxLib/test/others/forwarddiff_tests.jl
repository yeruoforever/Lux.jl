@testitem "Efficient JVPs" tags = [:misc] setup = [SharedTestSetup] begin
    using ForwardDiff, Zygote, ComponentArrays
    using LuxTestUtils: check_approx

    # Computes (∂f/∂x)u
    function jvp_forwarddiff(f::F, x, u) where {F}
        uu = reshape(u, axes(x))
        y =
            ForwardDiff.Dual{
                typeof(ForwardDiff.Tag(f, eltype(x))),eltype(x),1
            }.(x, ForwardDiff.Partials.(tuple.(uu)))
        return vec(ForwardDiff.partials.(vec(f(y)), 1))
    end

    function jvp_forwarddiff(f::F, x::ComponentArray, u) where {F}
        xx = getdata(x)
        uu = vec(u)
        y = ComponentArray(
            ForwardDiff.Dual{
                typeof(ForwardDiff.Tag(f, eltype(x))),eltype(x),1
            }.(xx, ForwardDiff.Partials.(tuple.(uu))),
            getaxes(x),
        )
        return vec(ForwardDiff.partials.(vec(f(y)), 1))
    end

    ## This exists exclusively for testing. It has horrifying performance implications
    jvp_forwarddiff_concrete(f::F, x, u) where {F} = ForwardDiff.jacobian(f, x) * vec(u)
    jvp_zygote(f::F, x, u) where {F} = only(Zygote.jacobian(f, x)) * vec(u)

    function test_jvp_computation(f::F, x, u, ongpu, nested=false) where {F}
        jvp₁ = jvp_forwarddiff(f, x, u)

        if !(x isa ComponentArray && ongpu)
            # ComponentArray + ForwardDiff on GPU don't play nice
            @testset "JVP ForwardDiff Concrete" begin
                jvp₂ = jvp_forwarddiff_concrete(f, x, u)
                @test check_approx(jvp₁, jvp₂; atol=1.0e-5, rtol=1.0e-5)
            end
        end

        if !nested
            @testset "JVP Zygote" begin
                jvp₃ = jvp_zygote(f, x, u)
                @test check_approx(jvp₁, jvp₃; atol=1.0e-5, rtol=1.0e-5)
            end
        end
    end

    @testset "$(mode): Jacobian Vector Products" for (mode, aType, ongpu, fp64) in MODES
        @testset "$(op)(; flipped = $flipped)" for flipped in (true, false),
            op in (depthwiseconv, conv)

            op === depthwiseconv && ongpu && continue

            input_dims = [(2, 4, 2, 1, 3), (4, 4, 1, 3), (4, 4, 3, 2), (4, 1, 3), (4, 3, 2)]
            weight_dims = if op === depthwiseconv
                [(2, 2, 2, 1, 1), (3, 3, 1, 1), (3, 3, 3, 3), (3, 1, 1), (3, 3, 3)]
            else
                [(2, 2, 2, 1, 4), (3, 3, 1, 4), (3, 3, 3, 2), (3, 1, 4), (3, 3, 2)]
            end

            @testset "Input Dims: $(in_dims) | Weight Dims: $(w_dims)" for (
                in_dims, w_dims
            ) in zip(
                input_dims, weight_dims
            )
                x = aType(randn(Float32, in_dims...))
                w = aType(randn(Float32, w_dims...))
                ux = aType(randn(Float32, size(x)...))
                uw = aType(randn(Float32, size(w)...))
                u = aType(randn(Float32, length(x) + length(w)))

                test_jvp_computation(x -> op(x, w; flipped), x, ux, ongpu)
                test_jvp_computation(w -> op(x, w; flipped), w, uw, ongpu)
                test_jvp_computation(
                    xw -> op(xw.x, xw.w; flipped), ComponentArray(; x, w), u, ongpu
                )

                op === depthwiseconv && continue

                # Zygote.gradient here is used to test the ∇conv_data and ∇conv_filter
                # functions. Also implicitly tests nested AD
                test_jvp_computation(
                    x -> only(Zygote.gradient(w -> sum(abs2, op(x, w; flipped)), w)),
                    x,
                    ux,
                    ongpu,
                    true,
                )
                test_jvp_computation(
                    x -> only(Zygote.gradient(x -> sum(abs2, op(x, w; flipped)), x)),
                    x,
                    ux,
                    ongpu,
                    true,
                )
                test_jvp_computation(
                    w -> only(Zygote.gradient(x -> sum(abs2, op(x, w; flipped)), x)),
                    w,
                    uw,
                    ongpu,
                    true,
                )
                test_jvp_computation(
                    w -> only(Zygote.gradient(w -> sum(abs2, op(x, w; flipped)), w)),
                    w,
                    uw,
                    ongpu,
                    true,
                )
                test_jvp_computation(
                    xw ->
                        only(Zygote.gradient(xw -> sum(abs2, op(xw.x, xw.w; flipped)), xw)),
                    ComponentArray(; x, w),
                    u,
                    ongpu,
                    true,
                )
            end
        end

        @testset for op in (logsoftmax, softmax)
            @testset for (input_dim, dim) in zip(
                ((2, 3), (2, 3), (2, 3, 4, 5), (2, 3, 4, 5), (2, 3, 4, 5), (2, 3, 4, 5)),
                (1, 2, 1, 2, 3, 4),
            )
                x = aType(randn(Float32, input_dim))
                u = aType(randn(Float32, input_dim))

                test_jvp_computation(x -> op(x; dims=dim), x, u, ongpu)

                test_jvp_computation(
                    x -> only(Zygote.gradient(x -> sum(op(x; dims=dim)), x)),
                    x,
                    u,
                    ongpu,
                    true,
                )
            end
        end

        @testset for op in (meanpool,)
            @testset for (input_dim, kernel_size, stride, pad) in (
                ((8, 3, 2), (4,), (2,), (0,)),
                ((8, 3, 2), (4,), (3,), (0,)),
                ((8, 3, 2), (4,), (3,), (1,)),
                ((8, 8, 3, 2), (4, 4), (2, 2), (0, 0)),
                ((8, 8, 3, 2), (4, 4), (3, 3), (0, 0)),
                ((8, 8, 3, 2), (4, 4), (3, 3), (1, 1)),
            )
                x = aType(randn(Float32, input_dim))
                u = aType(randn(Float32, input_dim))

                test_jvp_computation(x -> op(x, kernel_size; stride, pad), x, u, ongpu)

                # NNlib doesn't define ∇meanpool and ∇maxpool for AMDGPU properly
                mode == "amdgpu" && continue

                test_jvp_computation(
                    x ->
                        only(Zygote.gradient(x -> sum(op(x, kernel_size; stride, pad)), x)),
                    x,
                    u,
                    ongpu,
                    true,
                )
            end
        end
    end
end

@testitem "ForwardDiff dropout" tags = [:misc] setup = [SharedTestSetup] begin
    using ForwardDiff
    using LuxTestUtils: check_approx

    rng = StableRNG(12345)

    @testset "$mode: dropout" for (mode, aType, ongpu, fp64) in MODES
        x = aType(randn(rng, Float32, 10, 2))
        x_dual = ForwardDiff.Dual.(x)

        @test_nowarn dropout(rng, x_dual, 0.5f0, Val(true), 2.0f0, :)

        x_dropout = dropout(rng, x, 0.5f0, Val(true), 2.0f0, :)[1]
        x_dual_dropout =
            ForwardDiff.value.(dropout(rng, x_dual, 0.5f0, Val(true), 2.0f0, :)[1])

        @test check_approx(x_dropout, x_dual_dropout)
    end
end

@testitem "Gather/Scatter" tags = [:misc] setup = [SharedTestSetup] begin
    using ForwardDiff, NNlib

    @testset "gather" begin
        a = [1, 20, 300, 4000]
        ∂a = [-1, -20, -300, -4000]
        a_dual = ForwardDiff.Dual.(a, ∂a)

        res = NNlib.gather(a_dual, [2, 4, 2])
        @test ForwardDiff.value.(res) == [20, 4000, 20]
        @test ForwardDiff.partials.(res, 1) == [-20, -4000, -20]

        a = [1 2 3; 4 5 6]
        ∂a = [-1 -2 -3; -4 -5 -6]
        a_dual = ForwardDiff.Dual.(a, ∂a)

        res = NNlib.gather(a_dual, [1, 3, 1, 3, 1])
        @test ForwardDiff.value.(res) == [1 3 1 3 1; 4 6 4 6 4]
        @test ForwardDiff.partials.(res, 1) == [-1 -3 -1 -3 -1; -4 -6 -4 -6 -4]
    end

    @testset "scatter" begin
        a = [10, 100, 1000]
        ∂a = [-10, -100, -1000]
        a_dual = ForwardDiff.Dual.(a, ∂a)

        res = NNlib.scatter(+, a_dual, [3, 1, 2])
        @test ForwardDiff.value.(res) == [100, 1000, 10]
        @test ForwardDiff.partials.(res, 1) == [-100, -1000, -10]

        a = [1 2 3 4; 5 6 7 8]
        ∂a = [-1 -2 -3 -4; -5 -6 -7 -8]
        a_dual = ForwardDiff.Dual.(a, ∂a)

        res = NNlib.scatter(+, a_dual, [2, 1, 1, 5])
        @test ForwardDiff.value.(res) == [5 1 0 0 4; 13 5 0 0 8]
        @test ForwardDiff.partials.(res, 1) == [-5 -1 0 0 -4; -13 -5 0 0 -8]

        a = [10, 200, 3000]
        ∂a = [-10, -200, -3000]
        a_dual = ForwardDiff.Dual.(a, ∂a)

        res = NNlib.scatter(*, a_dual, [1, 4, 2]; init=10, dstsize=6)
        @test ForwardDiff.value.(res) == [100, 30000, 10, 2000, 10, 10]
        @test ForwardDiff.partials.(res, 1) == [-100, -30000, 10, -2000, 10, 10]
    end
end
