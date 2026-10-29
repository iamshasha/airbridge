using AirBridge.Engine;

namespace AirBridge.Core.Tests;

public class UpdateTests
{
    [Fact]
    public void VersionsCompareNumerically()
    {
        Assert.True(UpdateChecker.IsNewer("v0.10.0", "0.9.2"));
        Assert.True(UpdateChecker.IsNewer("v1.0", "0.9.9"));
        Assert.False(UpdateChecker.IsNewer("v0.3.0", "0.3.0"));
        Assert.False(UpdateChecker.IsNewer("v0.2.0", "0.3.0"));
    }

    [Fact]
    public void ReleaseJsonPicksThisPlatformsAsset()
    {
        const string json = """
            {"tag_name":"v0.4.0","body":"Faster","html_url":"https://github.com/iamshasha/airbridge/releases/tag/v0.4.0",
             "draft":false,"prerelease":false,"assets":[
               {"name":"AirBridge-win-x64.zip","size":5200,"browser_download_url":"https://example.com/x64.zip"},
               {"name":"AirBridge-win-arm64.zip","size":5100,"browser_download_url":"https://example.com/arm64.zip"}]}
            """;
        var update = UpdateChecker.Parse(json, "0.3.0", "AirBridge-win-arm64.zip")!;
        Assert.Equal("0.4.0", update.Version);
        Assert.Equal(new Uri("https://example.com/arm64.zip"), update.DownloadUrl);
        Assert.Equal(5100, update.DownloadSize);
        Assert.Null(UpdateChecker.Parse(json, "0.4.0", "AirBridge-win-x64.zip"));
        Assert.True(UpdateChecker.IsDue(null));
        Assert.False(UpdateChecker.IsDue(DateTimeOffset.Now.AddHours(-1)));
    }
}
