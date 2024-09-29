with import <nixpkgs> { };

mkShell {
  nativeBuildInputs = [
    xorg.libX11
    xorg.libX11.dev
    xorg.libXext
    xorg.libXi
    xorg.libXext.dev
    xorg.libXrandr
    xorg.libXinerama
    xorg.libXxf86vm
    xorg.libXcursor
    glfw
    libGL
    openssl.dev
  ];

  LD_LIBRARY_PATH = lib.makeLibraryPath [
    libGL
    xorg.libXext.dev
    glfw
    xorg.libXcursor
    xorg.libXinerama
    xorg.xinput
    xorg.libXi
    xorg.libXxf86vm
    xorg.libXrandr
    xorg.libX11.dev
    openssl.dev
  ];
}
