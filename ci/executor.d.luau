-- Executor environment definitions for luau-lsp analyze.
-- Only the globals EZ-UI-Library actually touches; extend as needed.
declare function gethui(): Instance
declare function writefile(path: string, contents: string): ()
declare function readfile(path: string): string
declare function isfile(path: string): boolean
declare function delfile(path: string): ()
declare function delfolder(path: string): ()
declare function listfiles(path: string): { string }
declare function isfolder(path: string): boolean
declare function makefolder(path: string): ()
declare function loadstring(source: string, chunkName: string?): ((...any) -> ...any)
declare function getgenv(): { [any]: any }
declare function setclipboard(contents: string): ()
declare function getclipboard(): string
declare function gethwid(): string
declare function base64_encode(data: string): string
declare function base64_decode(data: string): string
declare function request(options: { [string]: any }): { [string]: any }
declare function http_request(options: { [string]: any }): { [string]: any }
declare function firesignal(signal: RBXScriptSignal, ...: any): ()
declare function getconnections(signal: RBXScriptSignal): { any }

-- the library feature-detects multiple crypt shapes at runtime, so keep it loose
declare crypt: any
