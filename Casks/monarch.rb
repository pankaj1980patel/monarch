cask "monarch" do
  version "0.1.0"
  sha256 "dc0d2edd790b2dda8335020a6095657d7a453c6998491e53b17b1132b2ee5a6a"

  url "https://github.com/pankaj1980patel/monarch/releases/download/v#{version}/Monarch-#{version}.zip"
  name "Monarch"
  desc "Lightweight window manager: snapping, workspaces, window switcher, overview, gestures"
  homepage "https://github.com/pankaj1980patel/monarch"

  livecheck do
    url :url
    strategy :github_latest
  end

  # 0.1.0 is built for Apple silicon only. Remove this line once a release is universal.
  depends_on arch: :arm64
  depends_on macos: ">= :sequoia"

  app "Monarch.app"

  uninstall quit:      "dev.monarch.Monarch",
            launchctl: "dev.monarch.Monarch.agent"

  zap trash: "~/Library/Application Support/Monarch"

  caveats <<~EOS
    Monarch isn't notarized yet. If macOS refuses to open it, run:
      xattr -dr com.apple.quarantine "#{appdir}/Monarch.app"

    Then allow Monarch in System Settings → Privacy & Security → Accessibility.
  EOS
end
