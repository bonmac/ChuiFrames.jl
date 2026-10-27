@testmodule BrokenSetup begin
    const value = undefined_in_setup + 1
end

@testitem "setup module" setup = [BrokenSetup] begin
    @test BrokenSetup.value == 1
end
