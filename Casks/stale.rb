cask "stale" do
  version :latest
  sha256 :no_check

  url "https://stale.f-dobinciuc7.workers.dev/download"
  name "Stale"
  desc "Shows which files you use and which you can delete"
  homepage "https://stale.f-dobinciuc7.workers.dev/"

  depends_on macos: :monterey

  app "Stale.app"

  zap trash: [
    "~/Library/Application Support/Stale",
    "~/Library/Caches/dev.hustlecoding.stale",
    "~/Library/HTTPStorage/dev.hustlecoding.stale",
    "~/Library/Preferences/dev.hustlecoding.stale.plist",
  ]
end
