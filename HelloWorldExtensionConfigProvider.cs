using Microsoft.Azure.WebJobs.Description;
using Microsoft.Azure.WebJobs.Host.Config;
using Microsoft.Azure.Workflows.ServiceProviders.Abstractions;

namespace HelloWorldServiceProvider;

[Extension("HelloWorldServiceProvider", configurationSection: "HelloWorldServiceProvider")]
public sealed class HelloWorldExtensionConfigProvider : IExtensionConfigProvider
{
    public HelloWorldExtensionConfigProvider(
        ServiceOperationsProvider serviceOperationsProvider,
        HelloWorldServiceOperationProvider operationProvider)
    {
        serviceOperationsProvider.RegisterService(
            HelloWorldServiceOperationProvider.ServiceId,
            HelloWorldServiceOperationProvider.ServiceName,
            operationProvider);
    }

    public void Initialize(ExtensionConfigContext context)
    {
    }
}