__all__ = [
	"ClusterMonitor",
	"MatrixListener",
	"ServiceReporter",
	"UpdateManager",
	"WebhookServer",
]


def __getattr__(name):
	if name in {"ClusterMonitor", "ServiceReporter"}:
		from .ha import ClusterMonitor, ServiceReporter
		return {"ClusterMonitor": ClusterMonitor, "ServiceReporter": ServiceReporter}[name]
	if name == "MatrixListener":
		from .listener import MatrixListener
		return MatrixListener
	if name == "UpdateManager":
		from .update import UpdateManager
		return UpdateManager
	if name == "WebhookServer":
		from .webhook import WebhookServer
		return WebhookServer
	raise AttributeError(name)
