Signed release builds place the private llama-cli, llama-server, and whisper-cli
executables in this directory. They run as Myna-supervised child processes.

llama-server is an optional performance path: when "Keep the model warm" is
enabled, Myna starts llama-server bound to 127.0.0.1 (loopback only, on an
ephemeral port) so the language model loads once and stays resident between
requests. It never binds a public interface, never talks to the network off the
machine, and is torn down when the app quits or after an idle timeout. When the
warm server is disabled or fails to start, Myna falls back to spawning
llama-cli per request. All inference stays on this Mac either way.
