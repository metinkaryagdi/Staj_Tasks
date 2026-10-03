FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY src/InvoiceService.Domain/InvoiceService.Domain.csproj src/InvoiceService.Domain/
COPY src/InvoiceService.Application/InvoiceService.Application.csproj src/InvoiceService.Application/
COPY src/InvoiceService.Infrastructure/InvoiceService.Infrastructure.csproj src/InvoiceService.Infrastructure/
COPY src/InvoiceService.Api/InvoiceService.Api.csproj src/InvoiceService.Api/
RUN dotnet restore src/InvoiceService.Api/InvoiceService.Api.csproj
COPY src/ src/
RUN dotnet publish src/InvoiceService.Api/InvoiceService.Api.csproj -c Release -o /app --no-restore

FROM mcr.microsoft.com/dotnet/aspnet:10.0
WORKDIR /app
COPY --from=build /app .
EXPOSE 8080
ENTRYPOINT ["dotnet", "InvoiceService.Api.dll"]
