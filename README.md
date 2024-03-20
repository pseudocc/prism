# PRISM

Prism is a pure zig terminal manipulation library for Linux to build TUI programs.

## Quick Start

Enter the alternate screen, enable the raw mode, turn on mouse tracking,
take a look at the `examples/event.zig`.

![examples/event.zig](https://pseudocc.github.io/prism/event.gif) 

You may also want to run this example, which is pretty simple:

```bash
zig build examples
zig-out/bin/event
```

You could have an eye on `examples/widget.zig`, this is an example to manage
a simple widget (redraw after state changes).

### Prism Prompt

An extension library is still WIP, which is inspired by
[SBoudrias/Inquirer.js](https://github.com/SBoudrias/Inquirer.js).
This requires you to stay in canonical mode, and provides you a better UI with
in-time validation.

![examples/event.zig](https://pseudocc.github.io/prism/prompt.gif) 

## References

[Terminal Guide](https://terminalguide.namepad.de/)

[Entering raw mode](https://viewsourcecode.org/snaptoken/kilo/02.enteringRawMode.html)

## Nonsense

I was thinking of creating a UI module that provides layout managements 
and common widgets, but it would be pretty complicated for the users, and
I would like to make things simple, so that plan was dropped.
