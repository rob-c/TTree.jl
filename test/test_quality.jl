using Aqua
using JET

@testset "quality" begin
    @testset "Aqua" begin
        Aqua.test_all(TTree)
    end
    @testset "JET" begin
        JET.test_package(TTree; target_defined_modules=true)
    end
end
