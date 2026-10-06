using Microsoft.Azure.WebJobs;
using Microsoft.Azure.WebJobs.Hosting;
using Microsoft.Extensions.DependencyInjection.Extensions;

[assembly: WebJobsStartup(typeof(HelloWorldServiceProvider.HelloWorldStartup))]

namespace HelloWorldServiceProvider;

public sealed class HelloWorldStartup : IWebJobsStartup
{
    public void Configure(IWebJobsBuilder builder)
    {
        builder.AddExtension<HelloWorldExtensionConfigProvider>();
        builder.Services.TryAddSingleton<HelloWorldServiceOperationProvider>();
    }
}