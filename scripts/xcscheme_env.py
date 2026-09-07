#!/usr/bin/env python3
"""Shared helper for syncing an environment variable into an Xcode scheme."""

import getpass
import os
from pathlib import Path
import tempfile
import xml.etree.ElementTree as ET


def set_scheme_env(project, scheme_name, key, value, template=None):
    """Set key=value in scheme_name's LaunchAction environment variables.

    Updates the current user's existing xcscheme file if one is already present
    (e.g. because the scheme was run from Xcode at least once), otherwise creates
    one from template. Returns the written path, or None if the scheme has no
    user-specific file yet and no template was given, in which case nothing is
    written; the scheme is left as-is for interactive use in Xcode.
    """
    destination = (project / "xcuserdata" / (getpass.getuser() + ".xcuserdatad") /
                   "xcschemes" / (scheme_name + ".xcscheme"))
    if destination.exists():
        source = destination
    elif template is not None:
        source = template
    else:
        return None
    tree = ET.parse(source)
    launch = tree.getroot().find("LaunchAction")
    if launch is None:
        raise RuntimeError(f"Missing LaunchAction in {source}")
    variables = launch.find("EnvironmentVariables")
    if variables is None:
        variables = ET.SubElement(launch, "EnvironmentVariables")
    for variable in list(variables):
        if variable.get("key") == key:
            variables.remove(variable)
    ET.SubElement(variables, "EnvironmentVariable", key=key, value=value, isEnabled="YES")
    destination.parent.mkdir(parents=True, exist_ok=True)
    ET.indent(tree, space="   ")
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=destination.parent, delete=False) as output:
            temporary = Path(output.name)
            tree.write(output, encoding="UTF-8", xml_declaration=True)
        os.replace(temporary, destination)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    return destination
