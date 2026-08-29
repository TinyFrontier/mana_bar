cask "mana" do
  version "0.1.0"
  sha256 "f0e09b80eae61de26d3a332970af2656bb89053a87c6fdd69e9a44bfb213651d"

  url "https://github.com/TinyFrontier/mana_bar/releases/download/v#{version}/Mana-#{version}.dmg"
  name "Mana"
  desc "Menu bar panel showing how much of your AI subscription limits you have used"
  homepage "https://github.com/TinyFrontier/mana_bar"

  depends_on macos: :ventura

  app "Mana.app"

  # Mana is signed with an Apple Development certificate and is not notarized,
  # so Gatekeeper refuses it as if downloaded. Homebrew attaches the quarantine
  # attribute on install, which would leave an app that cannot be opened at all
  # without a right-click -> Open. Stripping it here is what makes a plain
  # `brew install --cask` usable; `caveats` says so out loud rather than doing
  # it behind the user's back. Remove this block once the app is notarized with
  # a Developer ID certificate.
  postflight do
    system_command "/usr/bin/xattr",
                   args:         ["-d", "com.apple.quarantine", "#{appdir}/Mana.app"],
                   must_succeed: false
  end

  uninstall quit: "com.manabar.Mana"

  zap trash: [
    "~/Library/Application Support/Mana",
    "~/Library/Preferences/com.manabar.Mana.plist",
    "~/Library/Saved Application State/com.manabar.Mana.savedState",
  ]

  caveats <<~EOS
    Mana is not notarized yet (that needs a paid Apple Developer Program
    membership), so this cask removes the download-quarantine attribute from
    the installed app. Without that, macOS would refuse to open it.

    Mana reads the OAuth logins the `claude` and `codex` CLIs already keep on
    this machine. The first read of Claude Code's Keychain item raises a macOS
    permission dialog once — choose "Always Allow" so background refreshes stay
    silent.
  EOS
end
