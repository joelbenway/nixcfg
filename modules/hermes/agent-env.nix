{pkgs}: {
  # List of Nixpkgs packages the agent requires on its PATH
  extraPackages = with pkgs; [
    ripgrep
    ffmpeg
    jq
    curl
  ];

  # Runtime overrides for Hermes's configuration
  # Active setup defined in default.nix (100% Free / $0.00 Token Cost):
  #   Primary Engine:       openrouter (nvidia/nemotron-3-ultra-550b-a55b:free) - $0.00
  #   Big Brain (Review):   nvidia (z-ai/glm-5.3-flash) - 1M Context / $0.00
  #   Media / Vision:       google (gemma-4-31b-it) - $0.00
  #   Compression:          nvidia (nvidia/nemotron-3.5-lightning-30b-a3b) - $0.00
  #   Fallbacks:            GLM 5.3 Flash ($0.00) -> Nemotron 3.5 Lightning ($0.00) -> Gemma 4 31B ($0.00) -> DeepSeek Flash (paid failover) -> Local Offline
  extraSettings = {
    # You can customize or override any specific role below:

    # If you ever want to re-enable DeepSeek V4.1 Flash for pure code synthesis:
    # model = {
    #   provider = "deepseek";
    #   default = "deepseek-flash";
    # };

    # If you want to use Nemotron 3.5 Lightning directly as primary instead of Ultra:
    # model = {
    #   provider = "nvidia";
    #   default = "nvidia/nemotron-3.5-lightning-30b-a3b";
    # };

    # agent = {
    #   max_turns = 80;
    # };
  };

  # Dynamically configured Model Context Protocol (MCP) servers
  mcpServers = {
    # Example stdio server:
    # fetch = {
    #   command = "${pkgs.python3Packages.mcp-server-fetch or pkgs.uv}/bin/uvx";
    #   args = ["mcp-server-fetch"];
    # };
  };
}
