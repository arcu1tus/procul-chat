using Microsoft.AspNetCore.Http.HttpResults;

namespace Procul.Api.Security.V1;

internal static class AuthEndpointsV1
{
    public static RouteGroupBuilder MapAuthV1(this RouteGroupBuilder group)
    {
        // Exchanging the password for a token must itself be unauthenticated.
        group.MapPost("/session", CreateSessionAsync).AllowAnonymous();

        // A lightweight validity probe: any authenticated request reaching this returns 204.
        group.MapGet("/session", ProbeSession).RequireAuthorization();

        return group;
    }

    private static Results<Ok<CreateSessionResponseV1>, UnauthorizedHttpResult> CreateSessionAsync(
        CreateSessionRequestV1 body,
        PasswordVerifier verifier,
        SessionTokenService tokens)
    {
        if (!verifier.Verify(body.Password))
        {
            // Deliberately generic: never reveal whether the password was close or empty.
            return TypedResults.Unauthorized();
        }

        var (token, expiresAt) = tokens.IssueToken();
        return TypedResults.Ok(new CreateSessionResponseV1(token, expiresAt));
    }

    private static NoContent ProbeSession() => TypedResults.NoContent();
}
