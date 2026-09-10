[CmdletBinding()]
param(
    [string]$Message,
    [string]$TrajectoryOut,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

$fastAgentRepo = Join-Path $PSScriptRoot 'fast-agent'
$fastAgentWheel = Join-Path $PSScriptRoot 'fast_agent_mcp-0.10.17-py3-none-any.whl'
$config = Join-Path $PSScriptRoot 'fast-agent.yaml'
$agentHome = Join-Path $PSScriptRoot 'fast-agent-home'
$agentCards = Join-Path $agentHome 'agent-cards'
$mainAgentCard = Join-Path $agentCards 'simo.md'
$overlay = Join-Path $agentHome 'model-overlays\simo-local.yaml'

$llamaDir = 'D:\llm\llama-b10679-bin-win-vulkan-x64'
$llamaServer = Join-Path $llamaDir 'llama-server.exe'
$modelPath = Join-Path $llamaDir '.\Dirk-Qwen3.8-27B-UD-Q6_K.gguf'
$modelId = '.\' + (Split-Path -Leaf $modelPath)

$useMcpServers = $true
$modelSpec = 'simo-local?reasoning=medium&temperature=0.3&top_p=0.9&top_k=20&min_p=0.0&repetition_penalty=1.0&streaming_timeout=600'
$serverUrl = 'http://127.0.0.1:8000'

function Invoke-FastAgent {
    if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
        throw 'Python was not found. Activate crescentmoon, then run this file again.'
    }

    if (-not (Test-Path -LiteralPath $fastAgentRepo -PathType Container)) {
        throw "Local fast-agent repository was not found: $fastAgentRepo"
    }

    if (-not (Test-Path -LiteralPath $mainAgentCard -PathType Leaf)) {
        throw "Main agent card was not found: $mainAgentCard"
    }

    if (-not (Test-Path -LiteralPath $llamaServer -PathType Leaf)) {
        throw "llama-server.exe was not found: $llamaServer"
    }

    if (-not (Test-Path -LiteralPath $modelPath -PathType Leaf)) {
        throw "GGUF model was not found: $modelPath"
    }

    $env:LLAMA_CPP_TOKEN = 'simo-made-this-shit'
    $env:PYTHONIOENCODING = 'utf-8'

    if (-not (Test-Path -LiteralPath $overlay -PathType Leaf)) {
        & python -m fast_agent.cli model llamacpp import `
            --home $agentHome `
            --url $serverUrl `
            --auth env `
            --api-key-env LLAMA_CPP_TOKEN `
            --name simo-local `
            $modelId

        if ($LASTEXITCODE -ne 0) {
            throw "Model import failed with exit code $LASTEXITCODE. Is llama-server running?"
        }
    }

    $fastAgentBootstrap = @'
import importlib
import runpy

mcp_session = importlib.import_module("mcp.client.session")
MCPAttachOptions = importlib.import_module(
    "fast_agent.mcp.mcp_aggregator"
).MCPAttachOptions

mcp_session.LATEST_HANDSHAKE_VERSION = "2025-06-18"
original_init = MCPAttachOptions.__init__

def init_with_longer_startup_budget(self, *args, **kwargs):
    if not args and "startup_timeout_seconds" not in kwargs:
        kwargs["startup_timeout_seconds"] = 60.0
    original_init(self, *args, **kwargs)

MCPAttachOptions.__init__ = init_with_longer_startup_budget
runpy.run_module("fast_agent.cli", run_name="__main__")
'@

    if ($TrajectoryOut) {
        if (-not [System.IO.Path]::IsPathRooted($TrajectoryOut)) {
            $TrajectoryOut = Join-Path $PSScriptRoot $TrajectoryOut
        }
        $TrajectoryOut = [System.IO.Path]::GetFullPath($TrajectoryOut)
    }

    $goArgs = @(
        'go'
        '--agent-cards'
        $agentCards
        '--agent'
        'simo'
        '--home'
        $agentHome
        '--workspace'
        $fastAgentRepo
        '--model'
        $modelSpec
        '--no-shell'
    )

    if ($Message) {
        $goArgs += @('--message', $Message)
    }
    if ($TrajectoryOut) {
        $goArgs += @('--trajectory-output', $TrajectoryOut)
    }
    if ($Quiet) {
        $goArgs += '--quiet'
    }

    if ($useMcpServers) {
        if (-not (Test-Path -LiteralPath $config -PathType Leaf)) {
            throw "MCP configuration was not found: $config"
        }

        $goArgs += @(
            '--config-path'
            $config
            '--servers'
            $mcpServers
        )
    }

    New-Item -ItemType Directory -Force -Path $agentHome | Out-Null
    $previousLocation = Get-Location
    try {
        Set-Location -LiteralPath $agentHome
        & python -c $fastAgentBootstrap @goArgs
        $exitCode = $LASTEXITCODE
    }
    finally {
        Set-Location -LiteralPath $previousLocation
    }

    exit $exitCode
}

# These names must match the keys in fast-agent.yaml.
$mcpServers = 'everything,filesystem,jcodemunch,patchloom,cartog'

Invoke-FastAgent
