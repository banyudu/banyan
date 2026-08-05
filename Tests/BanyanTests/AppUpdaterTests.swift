@testable import Banyan
import Foundation
import Testing

@Test func appVersionOrdersStableAndPrereleaseVersions() {
    #expect(AppVersion("v1.2.3")! < AppVersion("1.2.4")!)
    #expect(AppVersion("1.2.3-beta.2")! < AppVersion("1.2.3-beta.10")!)
    #expect(AppVersion("1.2.3-rc.1")! < AppVersion("1.2.3")!)
    #expect(AppVersion("1.2") == AppVersion("1.2.0"))
}

@Test func appReleaseSelectsDMGAsset() throws {
    let data = Data(#"""
    {
        "tag_name": "v1.2.4",
        "name": "Banyan 1.2.4",
        "html_url": "https://github.com/banyudu/banyan/releases/tag/v1.2.4",
        "assets": [
            {"name": "Banyan-1.2.4.dmg", "browser_download_url": "https://github.com/banyudu/banyan/releases/download/v1.2.4/Banyan-1.2.4.dmg"},
            {"name": "checksums.txt", "browser_download_url": "https://github.com/banyudu/banyan/releases/download/v1.2.4/checksums.txt"}
        ]
    }
    """#.utf8)

    let release = try JSONDecoder().decode(AppUpdateRelease.self, from: data)
    #expect(release.version == AppVersion("1.2.4"))
    #expect(release.packageAsset?.name == "Banyan-1.2.4.dmg")
}
