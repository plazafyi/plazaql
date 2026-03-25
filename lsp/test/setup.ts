// Ensure tree-sitter WASM is loaded before any tests run
import { parserReady } from "../src/parser.js";

await parserReady;
