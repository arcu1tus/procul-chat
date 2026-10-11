# syntax=docker/dockerfile:1

# ---------------------------------------------------------------------------
# Build stage: restore and publish the API.
#
# The project file is copied on its own first so the (slow) NuGet restore layer
# is reused until the dependencies actually change. The NuGet package cache is a
# BuildKit cache mount rather than a layer, so it survives layer invalidation and
# is shared across CI runs (see the workflow's `cache-from/to: type=gha`).
# ---------------------------------------------------------------------------
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src

COPY src/Procul.Api/Procul.Api.csproj src/Procul.Api/
RUN --mount=type=cache,target=/root/.nuget/packages \
    dotnet restore src/Procul.Api/Procul.Api.csproj

COPY src/Procul.Api/ src/Procul.Api/
RUN --mount=type=cache,target=/root/.nuget/packages \
    dotnet publish src/Procul.Api/Procul.Api.csproj \
        --configuration Release \
        --no-restore \
        --output /app

# ---------------------------------------------------------------------------
# Runtime stage: the ASP.NET Core runtime only (no SDK). Runs as the non-root
# `app` user that ships with the image and listens on 8080, the conventional
# non-root port.
# ---------------------------------------------------------------------------
FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS runtime
WORKDIR /app

ENV ASPNETCORE_URLS=http://+:8080

COPY --from=build /app .

USER app
EXPOSE 8080

ENTRYPOINT ["dotnet", "Procul.Api.dll"]
