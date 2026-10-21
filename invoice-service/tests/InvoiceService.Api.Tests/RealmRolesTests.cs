using System.Security.Claims;
using InvoiceService.Api.Auth;

namespace InvoiceService.Api.Tests;

public class RealmRolesTests
{
    [Fact]
    public void Each_realm_role_becomes_a_role_claim()
    {
        var identity = new ClaimsIdentity(
            [new Claim(RealmRoles.ClaimType, """{"roles":["fatura-izleyici","fatura-operatoru"]}""")], "test");

        RealmRoles.AddTo(identity);

        var user = new ClaimsPrincipal(identity);
        Assert.True(user.IsInRole(Roles.Viewer));
        Assert.True(user.IsInRole(Roles.Operator));
        Assert.False(user.IsInRole(Roles.InvoiceCreator));
    }

    [Fact]
    public void A_token_without_realm_roles_gets_no_role()
    {
        var identity = new ClaimsIdentity([new Claim("sub", "rolsuz")], "test");

        RealmRoles.AddTo(identity);

        Assert.Empty(identity.FindAll(identity.RoleClaimType));
    }
}