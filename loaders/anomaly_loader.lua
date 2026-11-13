local routes = {
    [7414497778] = "https://anomaly.pw/mtc4",
    [4750561026] = "https://anomaly.pw/coldwar",
    [73885730] = "https://anomaly.pw/prisonlife",
    [1526814825] = "https://anomaly.pw/wartycoon",
}
local url = routes[game.GameId]
if not url then
    setclipboard("https://discord.gg/auBaHr6juB")
    local player = game:GetService("Players").LocalPlayer
    if player then
        player:Kick("Game is unsupported, discord set to clipboard")
    end
    return
end

return loadstring(game:HttpGet(url))(...)
