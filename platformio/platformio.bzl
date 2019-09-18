# Copyright 2017 Google Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
################################################################################

"""PlatformIO Rules.

These are Bazel Skylark rules for building and uploading
[Arduino](https://www.arduino.cc/) programs using the
[PlatformIO](http://platformio.org/) build system.
"""


# The relative filename of the header file.
_HEADER_FILENAME = "lib/{dirname}/{filename}.h"


# The relative filename of the source file.
_SOURCE_FILENAME = "lib/{dirname}/{filename}.cpp"


# The relative filename of an additional file (header or source) defined for a
# platformio_library target.
_ADDITIONAL_FILENAME = "lib/{dirname}/{filename}"


# Command that copies the source to the destination.
_COPY_COMMAND="cp {source} {destination}"


# Command that zips files recursively. It enters the output directory first so
# that the zipped path starts at lib/.
_ZIP_COMMAND="cd {output_dir} && zip -r -u {zip_filename} lib/"


# Command that unzips a zip archive into the specified directory.
_UNZIP_COMMAND="unzip -o -d {project_dir} {zip_filename}"


# Command that executes the PlatformIO build system and builds the project in
# the specified directory.
_BUILD_COMMAND="platformio run -d {project_dir}"


# Command that executes the PlatformIO build system and uploads the compiled
# firmware to the device.
_UPLOAD_COMMAND="platformio run -d {project_dir} -t upload"


# Header used in the shell script that makes platformio_project executable.
# Execution will upload the firmware to the Arduino device.
_SHELL_HEADER="""#!/bin/bash"""

# Locations to search for the PlatformIO and other binaries
_SEARCH_PATH = "/bin:/usr/bin:/usr/local/bin:/usr/sbin:/sbin"

def _platformio_library_impl(ctx):
  """Collects all transitive dependencies and emits the zip output.

  Outputs a zip file containing the library in the directory structure expected
  by PlatformIO.

  Args:
    ctx: The Skylark context.
  """
  name = ctx.label.name

  # Copy the header file to the desired destination.
  header_file = ctx.actions.declare_file(
      _HEADER_FILENAME.format(dirname=name, filename=name))
  inputs = [ctx.file.hdr]
  outputs = [header_file]
  commands = [_COPY_COMMAND.format(
      source=ctx.file.hdr.path, destination=header_file.path)]

  # Copy all the additional header and source files.
  for additional_files in [ctx.attr.add_hdrs, ctx.attr.add_srcs]:
    for target in additional_files:
      if len(target.files.to_list()) != 1:
        fail("each target listed under add_hdrs or add_srcs must expand to " +
             "exactly one file, this expands to %d: %s" %
             (len(target.files), target.files))
      # The name of the label is the relative path to the file, this enables us
      # to prepend "lib/" to the path. For PlatformIO, all the library files
      # must be under lib/...
      additional_file_name = target.label.name
      additional_file_source = [f for f in target.files.to_list()][0]
      additional_file_destination = ctx.actions.declare_file(
        _ADDITIONAL_FILENAME.format(dirname=name, filename=additional_file_name))
      inputs.append(additional_file_source)
      outputs.append(additional_file_destination)
      commands.append(_COPY_COMMAND.format(
          source=additional_file_source.path,
          destination=additional_file_destination.path))

  # The src argument is optional, some C++ libraries might only have the header.
  if ctx.attr.src != None:
    source_file = ctx.actions.declare_file(
        _SOURCE_FILENAME.format(dirname=name, filename=name))
    inputs.append(ctx.file.src)
    outputs.append(source_file)
    commands.append(_COPY_COMMAND.format(
        source=ctx.file.src.path, destination=source_file.path))
 
  # Zip the entire content of the library folder.
  outputs.append(ctx.outputs.zip)
  commands.append(_ZIP_COMMAND.format(
      output_dir=ctx.outputs.zip.dirname, zip_filename=ctx.outputs.zip.basename))
  ctx.actions.run_shell(
      inputs=inputs,
      outputs=outputs,
      command="\n".join(commands),
  )

  # Collect the zip files produced by all transitive dependancies.
  transitive_zip_files=depset([ctx.outputs.zip])
  for dep in ctx.attr.deps:
    transitive_zip_files = depset(transitive=[
        transitive_zip_files, dep.transitive_zip_files
    ])
  return struct(
    transitive_zip_files=transitive_zip_files,
  )


def _emit_ini_file_action(ctx):
  """Emits a Bazel action that generates the PlatformIO configuration file.

  Args:
    ctx: The Skylark context.
  """
  environment_kwargs = []
  if ctx.attr.environment_kwargs:
    environment_kwargs.append("")

  for key, value in ctx.attr.environment_kwargs.items():
    if key == "" or value == "":
      continue
    environment_kwargs.append("{key} = {value}".format(key=key, value=value))
  ctx.actions.expand_template(
      template=ctx.file._platformio_ini_tmpl,
      output=ctx.outputs.platformio_ini,
      substitutions={
          "%board%": ctx.attr.board,
          "%platform%": ctx.attr.platform,
          "%framework%": ctx.attr.framework,
          "%environment_kwargs%": "\n".join(environment_kwargs),
      },
  )


def _emit_main_file_action(ctx):
  """Emits a Bazel action that outputs the project main C++ file.

  Args:
    ctx: The Skylark context.
  """
  ctx.actions.run_shell(
      inputs=[ctx.file.src],
      outputs=[ctx.outputs.main_cpp],
      command=_COPY_COMMAND.format(
          source=ctx.file.src.path, destination=ctx.outputs.main_cpp.path),
  )


def _emit_build_action(ctx, project_dir):
  """Emits a Bazel action that unzips the libraries and builds the project.

  Args:
    ctx: The Skylark context.
    project_dir: A string, the main directory of the PlatformIO project.
      This is where the zip files will be extracted.
  """
  transitive_zip_files = depset()
  for dep in ctx.attr.deps:
    transitive_zip_files = depset(transitive=[
        transitive_zip_files, dep.transitive_zip_files
    ])

  commands = []
  for zip_file in transitive_zip_files.to_list():
    commands.append(_UNZIP_COMMAND.format(
        project_dir=project_dir, zip_filename=zip_file.path))
  commands.append(_BUILD_COMMAND.format(project_dir=project_dir))

  # The PlatformIO build system needs the project configuration file, the main
  # file and all the transitive dependancies.
  inputs=[ctx.outputs.platformio_ini, ctx.outputs.main_cpp]
  for zip_file in transitive_zip_files.to_list():
    inputs.append(zip_file)
  ctx.actions.run_shell(
      inputs=inputs,
      outputs=[ctx.outputs.firmware_elf],
      command="\n".join(commands),
      env={
        # The PlatformIO binary assumes that the build tools are in the path.
        "PATH":"/bin:/usr/bin:/usr/local/bin:/usr/sbin:/sbin",
      },
      execution_requirements={
        # PlatformIO cannot be executed in a sandbox.
        "local": "1",
      },
  )


def _emit_executable_action(ctx):
  """Emits a Bazel action that produces executable script.

  When the script is executed, the compiled firmware gets uploaded to the
  Arduino device.

  Args:
    ctx: The Skylark context.
  """
  # TODO(mum4k): Make this script smarter, when executed via Bazel, the current
  # directory is project_name.runfiles/__main__ so we need to go two dirs up.
  # This however won't work when executed directly.
  content=[_SHELL_HEADER, _UPLOAD_COMMAND.format(project_dir="../..")]
  ctx.actions.write(
      output=ctx.outputs.executable,
      content="\n".join(content),
      is_executable=True,
  )


def _platformio_project_impl(ctx):
  """Builds and optionally uploads (when executed) a PlatformIO project.

  Outputs the C++ source file containing the Arduino setup() and loop()
  functions renamed according to PlatformIO needs, a platformio_ini with the
  project configuration file for PlatformIO and the firmware. The firmware_elf
  is the compiled version of the Arduino firmware for the specified board.

  Args:
    ctx: The Skylark context.
  """
  _emit_ini_file_action(ctx)
  _emit_main_file_action(ctx)

  # Determine the build directory used by Bazel, that is the directory where
  # our output files will be placed.
  project_dir = ctx.outputs.platformio_ini.dirname
  _emit_build_action(ctx, project_dir)
  _emit_executable_action(ctx)

def _platformio_toolchain_impl(ctx):
    """Tweaks locations for PlatformIO and related binaries.

    Args:
      ctx: The Skylark context.
    """
    _COPY_COMMAND = ctx.attr.copy_command
    _ZIP_COMMAND = ctx.attr.zip_command
    _UNZIP_COMMAND = ctx.attr.unzip_command
    _BUILD_COMMAND = ctx.attr.build_command
    _UPLOAD_COMMAND = ctx.attr.upload_command
    _SHELL_HEADER = ctx.attr.shell_header
    _SEARCH_PATH = ctx.attr.search_path

platformio_library = rule(
  implementation=_platformio_library_impl,
  outputs = {
      "zip": "%{name}.zip",
  },
  attrs={
    "hdr": attr.label(
        allow_single_file=[".h", ".hpp"],
        mandatory=True,
        doc = "A string, the name of the C++ header file. This is mandatory.",
    ),
    "src": attr.label(
        allow_single_file=[".c", ".cc", ".cpp"],
        doc = "A string, the name of the C++ source file. This is optional.",
    ),
    "add_hdrs": attr.label_list(
        allow_files=[".h", ".hpp"],
        allow_empty=True,
        doc = """
A list of labels, additional header files to include in the resulting zip file.
""",
    ),
    "add_srcs": attr.label_list(
        allow_files=[".c", ".cc", ".cpp"],
        allow_empty=True,
        doc = """
A list of labels, additional source files to include in the resulting zip file.
""",
    ),
    "deps": attr.label_list(
        providers=["transitive_zip_files"],
        doc = """
A list of Bazel targets, other platformio_library targets that this one depends on.
""",
    ),
  },
  doc = """
Defines a C++ library that can be imported in an PlatformIO project.

The PlatformIO build system requires a set project directory structure. All
libraries must be under the lib directory. Furthermore all libraries can only
consist of a single header and a single source file. The name of the library
must match the names of the header file, the source file and the subdirectory
under the lib directory.

If you have a C++ library with files my_lib.h and my_lib.cc, using this rule:

```
platformio_library(
    # Start with an uppercase letter to keep the Arduino naming style.
    name = "My_lib",
    hdr = "my_lib.h",
    src = "my_lib.cc",
)
```

Will generate a zip file containing the following structure:

```
lib/
  My_lib/
    My_lib.h
    My_lib.cpp
```

In the Arduino code, you should include this as follows. The PLATFORMIO_BUILD
will be set when the library is built by the PlatformIO build system.

```
#ifdef PLATFORMIO_BUILD
#include <My_lib.h>  // This is how PlatformIO sees and includes the library.
#else
#include "actual/path/to/my_lib.h" // This is for native C++.
#endif
```

Outputs a single zip file containing the C++ library in the directory structure
expected by PlatformIO.
"""
)

platformio_project = rule(
    implementation=_platformio_project_impl,
    executable=True,
    outputs = {
      "main_cpp": "src/main.cpp",
      "platformio_ini": "platformio.ini",
      "firmware_elf": ".pio/build/%{board}/firmware.elf",
    },
    attrs={
      "_platformio_ini_tmpl": attr.label(
        default=Label("//platformio:platformio_ini_tmpl"),
        allow_single_file=True,
      ),
      "src": attr.label(
        allow_single_file=[".cc"],
        mandatory=True,
        doc = """
A string, the name of the C++ source file, the main file for 
the project that contains the Arduino setup() and loop() functions. This is mandatory.
""",
      ),
      "board": attr.string(
        mandatory=True,
        doc = """
A string, name of the Arduino board to build this project for. You can
find the supported boards in the
[PlatformIO Embedded Boards Explorer](http://platformio.org/boards). This is
mandatory.
""",
      ),
      "platform": attr.string(
        default="atmelavr",
        doc = """
A string, the name of the
[development platform](
http://docs.platformio.org/en/latest/platforms/index.html#platforms) for
this project.
""",
      ),
      "framework": attr.string(
        default="arduino",
        doc = """
A string, the name of the
[framework](
http://docs.platformio.org/en/latest/frameworks/index.html#frameworks) for
this project.
""",
      ),
      "environment_kwargs": attr.string_dict(
        allow_empty=True,
        doc = """
A dictionary of strings to strings, any provided keys and
values will directly appear in the generated platformio.ini file under the
env:board section. Refer to the [Project Configuration File manual](
http://docs.platformio.org/en/latest/projectconf.html) for the available
options.
""",
      ),
      "deps": attr.label_list(
        providers=["transitive_zip_files"],
        doc = """
A list of Bazel targets, the platformio_library targets that this one
depends on.
""",
      ),
    },
    doc = """
Defines a project that will be built and uploaded using PlatformIO.

Creates, configures and runs a PlatformIO project. This is equivalent to running:

```
platformio run
```

This rule is executable and when executed, it will upload the compiled firmware
to the connected Arduino device. This is equivalent to running:
platformio run -t upload


Outputs the C++ source file containing the Arduino setup() and loop()
functions renamed according to PlatformIO needs, a platformio_ini with the
project configuration file for PlatformIO and the firmware. The firmware_elf
is the compiled version of the Arduino firmware for the specified board and
the firmware_hex is the firmware in the hexadecimal format ready for
uploading.
""",
)

platformio_toolchain = rule(
    implementation = _platformio_toolchain_impl,
    attrs = {
        "copy_command": attr.string(
            default = _COPY_COMMAND,
            doc = "Command that copies the source to the destination.",
        ),
        "zip_command": attr.string(
            default = _ZIP_COMMAND,
            doc = """
Command that zips files recursively. It enters the output directory first so
that the zipped path starts at lib/.""",
        ),
        "unzip_command": attr.string(
            default = _UNZIP_COMMAND,
            doc = "Command that unzips a zip archive into the specified directory.",
        ),
        "build_command": attr.string(
            default = _BUILD_COMMAND,
            doc = """
Command that executes the PlatformIO build system and builds the project in
the specified directory.""",
        ),
        "upload_command": attr.string(
            default = _UPLOAD_COMMAND,
            doc = """
Command that executes the PlatformIO build system and uploads the compiled
firmware to the device.""",
        ),
        "shell_header": attr.string(
            default = _SHELL_HEADER,
            doc = """
Header used in the shell script that makes platformio_project executable.
Execution will upload the firmware to the Arduino device.""",
        ),
        "search_path": attr.string(
            default = _SEARCH_PATH,
            doc = "Locations to search for the PlatformIO and other binaries",
        ),
    },
    doc = """
Optionally tweaks locations for PlatformIO and related binaries.
""",
)
