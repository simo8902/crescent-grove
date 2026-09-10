A fast-agent-focused fork of Crescent Grove that turns Crescent’s character systems into a persistent runtime layer
instead of a separate chat application.

It preserves Crescent Grove’s long-term memory, episodic RAG memory, Wyrd associative flashbacks, Salia reflection,
MoonTide emotional state, desires, vitals, summaries, image memories, repetition protection, conversation logs, and
autonomous internal events. Fast-agent remains the main runtime for local LLM inference, MCP servers, tool execution,
engineering workflows, and terminal interaction.

The integration injects live character state and relevant memories into each turn without replacing the user’s own
persona instructions. Mutable state is kept outside the static system prefix so llama.cpp KV-cache reuse still works.
Crescent’s UI, web server, native tool loop, and native chat/model loop are intentionally not used.
