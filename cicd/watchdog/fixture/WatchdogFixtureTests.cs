namespace Tier0.Watchdog.Fixture;

using NUnit.Framework;

public sealed class WatchdogFixtureTests
{
    [Test]
    public void CleanFollowupPasses() => Assert.That(2 + 2, Is.EqualTo(4));

    [Test]
    public void RealTesthostCanBeMadeUnresponsive()
    {
        if (Environment.GetEnvironmentVariable("TIER0_REAL_HANG") != "1")
            Assert.Pass();

        Thread.Sleep(Timeout.Infinite);
    }
}
