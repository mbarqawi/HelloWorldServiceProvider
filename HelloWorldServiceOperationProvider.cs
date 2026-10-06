using System.Net;
using Microsoft.Azure.Workflows.ServiceProviders.Abstractions;
using Microsoft.Azure.Workflows.ServiceProviders.WebJobs.Abstractions.Providers;
using Microsoft.WindowsAzure.ResourceStack.Common.Collections;
using Microsoft.WindowsAzure.ResourceStack.Common.Extensions;
using Microsoft.WindowsAzure.ResourceStack.Common.Swagger.Entities;
using Newtonsoft.Json.Linq;

namespace HelloWorldServiceProvider;

[ServiceOperationsProvider(Id = ServiceId, Name = ServiceName)]
public sealed class HelloWorldServiceOperationProvider : IServiceOperationsProvider
{
    public const string ServiceName = "helloWorld";
    public const string ServiceId = "/serviceProviders/helloWorld";
    public const string OperationId = "helloWorld";

    private static readonly ServiceOperationApi Api = new()
    {
        Name = ServiceName,
        Id = ServiceId,
        Type = DesignerApiType.ServiceProvider,
        Properties = new ServiceOperationApiProperties
        {
            BrandColor = 0x0078D4,
            Description = "Returns a Hello World greeting.",
            DisplayName = "Hello World",
            Capabilities = new[] { ApiCapability.Actions },
            ConnectionParameters = new ConnectionParameters(),
        },
    };

    private readonly InsensitiveDictionary<ServiceOperation> operations;
    private readonly List<ServiceOperation> operationsWithManifest;

    public HelloWorldServiceOperationProvider()
    {
        ServiceOperation operation = new()
        {
            Name = OperationId,
            Id = OperationId,
            Type = "HelloWorld",
            Properties = new ServiceOperationProperties
            {
                Api = Api.GetFlattenedApi(),
                Summary = "Say hello",
                Description = "Returns a greeting for the supplied name.",
                Visibility = Visibility.Important,
                OperationType = OperationType.ServiceProvider,
                BrandColor = 0x0078D4,
            },
        };

        this.operations = new InsensitiveDictionary<ServiceOperation>
        {
            { OperationId, operation },
        };

        this.operationsWithManifest = new List<ServiceOperation>
        {
            operation.CloneWithManifest(CreateManifest()),
        };
    }

    public string GetBindingConnectionInformation(
        string operationId,
        InsensitiveDictionary<JToken> connectionParameters) => string.Empty;

    public IEnumerable<ServiceOperation> GetOperations(bool expandManifest) =>
        expandManifest ? this.operationsWithManifest : this.operations.Values;

    public ServiceOperationApi GetService() => Api;

    public Task<ServiceOperationResponse> InvokeOperation(
        string operationId,
        InsensitiveDictionary<JToken> connectionParameters,
        ServiceOperationRequest serviceOperationRequest)
    {
        if (!string.Equals(operationId, OperationId, StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException($"Unsupported operation '{operationId}'.");
        }

        string name = serviceOperationRequest.Parameters?["name"]?.Value<string>() ?? "World";
        ServiceOperationResponse response = new HelloWorldServiceOperationResponse(
            JObject.FromObject(new { message = $"Hello, {name}!" }),
            HttpStatusCode.OK);

        return Task.FromResult(response);
    }

    private static ServiceOperationManifest CreateManifest() => new()
    {
        ConnectionReference = new ConnectionReferenceFormat
        {
            ReferenceKeyFormat = ConnectionReferenceKeyFormat.ServiceProvider,
        },
        Settings = new OperationManifestSettings
        {
            SecureData = new OperationManifestSettingWithOptions<SecureDataOptions>(),
            TrackedProperties = new OperationManifestSetting
            {
                Scopes = new[] { OperationScope.Action },
            },
        },
        InputsLocation = new[] { InputsLocation.Inputs, InputsLocation.Parameters },
        Inputs = new SwaggerSchema
        {
            Type = SwaggerSchemaType.Object,
            Properties = new OrdinalDictionary<SwaggerSchema>
            {
                {
                    "name",
                    new SwaggerSchema
                    {
                        Type = SwaggerSchemaType.String,
                        Title = "Name",
                        Description = "The name to greet.",
                    }
                },
            },
        },
        Outputs = new SwaggerSchema
        {
            Type = SwaggerSchemaType.Object,
            Properties = new OrdinalDictionary<SwaggerSchema>
            {
                {
                    "body",
                    new SwaggerSchema
                    {
                        Type = SwaggerSchemaType.Object,
                        Properties = new OrdinalDictionary<SwaggerSchema>
                        {
                            {
                                "message",
                                new SwaggerSchema
                                {
                                    Type = SwaggerSchemaType.String,
                                    Title = "Greeting",
                                }
                            },
                        },
                    }
                },
            },
        },
        Connector = Api,
    };
}

internal sealed class HelloWorldServiceOperationResponse : ServiceOperationResponse
{
    public HelloWorldServiceOperationResponse(JToken body, HttpStatusCode statusCode)
        : base(body, statusCode)
    {
    }

    public override Task CompleteOperation() => Task.CompletedTask;

    public override Task FailOperation() => Task.CompletedTask;
}