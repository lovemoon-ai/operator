"""Host-side services the Operator app connects to.

A service owns a channel of the Operator protocol and orchestrates whatever
library does the actual work. Services never implement robot algorithms
themselves.
"""

from .retargeting import RetargetingConnection, create_app, serve

__all__ = ["RetargetingConnection", "create_app", "serve"]
