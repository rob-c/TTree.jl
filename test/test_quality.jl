using Aqua
using JET

@testset "quality" begin
    @testset "Aqua" begin
        # The persistent-task check resolves this package in an environment of
        # its own, which cannot be done while XRootD 0.3 is unregistered: the
        # resolver has no 0.3 to find. Turn it back on once XRootD is released.
        Aqua.test_all(TTree; persistent_tasks=false)
    end
    @testset "JET" begin
        JET.test_package(TTree; target_defined_modules=true)
    end
end
