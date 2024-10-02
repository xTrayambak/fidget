# Dios - a GUI framework that is a fork of Fidget, focused solely on Linux and Wayland.

`nimble install https://github.com/xTrayambak/dios`

## About
Dios is a hard fork of Fidget that aims to be akin to something like [Iced](https://iced.rs), allowing programmers to make GUIs targetting Linux.

Dios uses plain nim-procs, nim-templates, if-statements and for-loops.

# Backends

Dios has several backends that are planned:
* Linux (best supported)
* Windows (supported, but not a target)
* Mac (supported, but not a target)

As a hard fork of Fidget, it used to have a HTML backend, but that is now removed and no longer supported.

# Philosophy - Minimalism

The main idea of fidget is to use standard imperative nim paradigms like nim-procs, nim-for-loops, nim-ifs, nim-templates instead of say providing a custom language, XML templates, HTML, Jinja templates, CSS ...

Instead of creating CSS classes you just create a nim proc or a nim template with the things you want and reuse that. Instead of having some sort of list controller you just use a for loop to position your list elements.

There are very little UI layout primitives just align left, center, right, both, or scale for the X axis and top, center, bottom, both, or scale for the Y axis. There is none of margin, padding, float, absolute, relative, border box, flex, recycle view controllers, stack layout, constraints ...

If you want to do something fancy just do a little math. Many times a simple math formula is smaller, simpler, and easier to figure out then layout puzzles.

# Why Nim?

Nim is a great languages because it’s easy on the eyes like Python, but typed and is performant as C. It can also compile to JavaScript, C, C++, ObjC. Nim is a great language for UI design because it has advanced templates and macros can make a really good DSL (domain specific language) - that makes writing UIs straightforward, intuitive and crossplatform.

# Imperative UI Style

I like imperative style of programming. This is a style you probably learned to program at the start, but was forced to abandon with more complex and ill fitting object oriented style. Imperative style to me means when you are only using functions, if-statements and for-loops. Imperative style to me means simple data structures of structs, lists and tables. Simple functions that read from top to bottom with as few branches as possible.

Each UI frame is drawn completely from start to finish all in the code you control. Use of callbacks is discouraged. Think liner, think simple. After any event by the user, data or timer, the UI is redrawn. The UI is redrawn in an efficient way as to allow this. With HTML a modification cache is used to ensure only a minimal amount of DOM changes are needed. With OpenGL you redraw the whole screen using as few state transitions and batching everything into a texture atlas and single global vertex buffer.
