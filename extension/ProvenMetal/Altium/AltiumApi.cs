using DXP;
using EDP;
using SCH;

namespace ProvenMetal.Altium
{
    // Thin accessors for the Altium API from C#, matching the pattern used by
    // shipping C# extensions (DXP.GlobalVars.Client / .DXPWorkSpace, StartServer).
    internal static class AltiumApi
    {
        public static IClient Client => DXP.GlobalVars.Client;

        // The Workspace Manager (a.k.a. Design Manager) - exposes DM_FocusedProject,
        // DM_DocumentFlattened, DM_Components, etc. (the same interfaces the KiCad/
        // Altium DelphiScript plugin used).
        public static IWorkspace Workspace => DXP.GlobalVars.DXPWorkSpace as IWorkspace;

        private static ISch_ServerInterface _sch;
        public static ISch_ServerInterface SchServer
        {
            get
            {
                if (_sch == null)
                {
                    Client.StartServer("SCH");
                    _sch = Client.GetServerModuleByName("SCH") as ISch_ServerInterface;
                }
                return _sch;
            }
        }
    }
}
