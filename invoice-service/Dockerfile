FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY src/InvoiceService/InvoiceService.csproj src/InvoiceService/
RUN dotnet restore src/InvoiceService/InvoiceService.csproj
COPY src/InvoiceService/ src/InvoiceService/
RUN dotnet publish src/InvoiceService/InvoiceService.csproj -c Release -o /app --no-restore

FROM mcr.microsoft.com/dotnet/aspnet:10.0
WORKDIR /app
COPY --from=build /app .
EXPOSE 8080
ENTRYPOINT ["dotnet", "InvoiceService.dll"]
