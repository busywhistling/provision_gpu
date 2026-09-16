"""An AWS Python Pulumi program"""

import pathlib
import sys

# Pulumi's python language host does not place the program directory on
# sys.path, and cwd (and therefore __file__) is relative to src/, so resolve
# first to allow importing sibling modules and finding project-root files.
_top = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(_top))

import pulumi

from cuda_instance import setup_instance


def main():
    ami, _sg, _key_pair, instance = setup_instance()

    # --- Outputs ---
    pulumi.export("instance_id", instance.id)
    pulumi.export("public_ip", instance.public_ip)
    pulumi.export("ami_used", ami.id)


main()
