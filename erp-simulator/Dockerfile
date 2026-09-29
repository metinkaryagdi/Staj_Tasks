FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY src/ErpSimulator/ErpSimulator.csproj src/ErpSimulator/
RUN dotnet restore src/ErpSimulator/ErpSimulator.csproj
COPY src/ErpSimulator/ src/ErpSimulator/
RUN dotnet publish src/ErpSimulator/ErpSimulator.csproj -c Release -o /app --no-restore

FROM mcr.microsoft.com/dotnet/aspnet:10.0
WORKDIR /app
COPY --from=build /app .
EXPOSE 8080
ENTRYPOINT ["dotnet", "ErpSimulator.dll"]
