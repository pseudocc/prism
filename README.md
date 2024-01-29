# PRISM

Prism is a pure zig terminal manipulation library for Linux to build TUI programs.

## Quick Start

Enter the alternate screen, enable the raw module, turn on mouse tracking,
take a look at the `examples/event.zig`.

![examples/event.zig](https://pseudocc.github.io/prism/event.gif) 

You may also want to run this example, which is pretty simple:

```bash
zig build examples
zig-out/bin/event
```

You could have an eye on `examples/widget.zig`, this is an example to manage
a simple widget (redraw after state changes).

## References

[Terminal Guide](https://terminalguide.namepad.de/)

[Entering raw mode](https://viewsourcecode.org/snaptoken/kilo/02.enteringRawMode.html)
