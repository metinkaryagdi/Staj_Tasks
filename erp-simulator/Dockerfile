FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY src/ErpSimulator.Domain/ErpSimulator.Domain.csproj src/ErpSimulator.Domain/
COPY src/ErpSimulator.Application/ErpSimulator.Application.csproj src/ErpSimulator.Application/
COPY src/ErpSimulator.Infrastructure/ErpSimulator.Infrastructure.csproj src/ErpSimulator.Infrastructure/
COPY src/ErpSimulator.Api/ErpSimulator.Api.csproj src/ErpSimulator.Api/
RUN dotnet restore src/ErpSimulator.Api/ErpSimulator.Api.csproj
COPY src/ src/
RUN dotnet publish src/ErpSimulator.Api/ErpSimulator.Api.csproj -c Release -o /app --no-restore

FROM mcr.microsoft.com/dotnet/aspnet:10.0
WORKDIR /app
COPY --from=build /app .
EXPOSE 8080
ENTRYPOINT ["dotnet", "ErpSimulator.Api.dll"]
