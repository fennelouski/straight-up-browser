import JavaScriptCore
import Testing
@testable import Browser

@Suite("Bounded page edge sampler")
struct MobilePageEdgeTests {
    @MainActor private func sample(_ fixture: String) throws -> [Double] {
        let context = try #require(JSContext())
        context.evaluateScript("""
        var innerWidth=390,innerHeight=700,window={visualViewport:null};
        var root={},nodes=[],NodeFilter={SHOW_ELEMENT:1};
        var document={body:root,documentElement:root,createTreeWalker:()=>{let i=0;return {nextNode:()=>nodes[i++]||null};}};
        function node(top,position='fixed',parent=root){return {
          parentElement:parent,
          style:{position,visibility:'visible',opacity:'1',transform:'none',perspective:'none',filter:'none',contain:'none',willChange:'auto',borderTopWidth:'1px',borderBottomWidth:'0px'},
          getBoundingClientRect:()=>({top,bottom:top+40,width:390,height:40})};}
        function getComputedStyle(e){return e.style;}
        """)
        context.evaluateScript(fixture)
        let value = context.evaluateScript(MobilePageChrome.fixedEdgeScript)
        #expect(context.exception == nil)
        return (value?.objectForKeyedSubscript("edges")?.toArray() as? [Double]) ?? []
    }

    @MainActor @Test func onlyVisibleViewportFixedBordersQualify() throws {
        let edges = try sample("nodes=[node(80),node(150,'sticky'),node(200,'static'),node(-100),node(750)];nodes[0].style.borderBottomWidth='1px';")
        #expect(edges == [80, 120])
        #expect(try sample("nodes=[node(80)];nodes[0].style.opacity='0';").isEmpty)
    }

    @MainActor @Test func transformedContainingBlocksAreNotStationaryTargets() throws {
        let edges = try sample("var p=node(0);p.style.transform='translateX(1px)';nodes=[node(80,'fixed',p)];")
        #expect(edges.isEmpty)
    }

    @MainActor @Test func traversalAndOutputAreBounded() throws {
        #expect(try sample("nodes=Array.from({length:1000},(_,i)=>node(i));").count == 24)
        #expect(try sample("nodes=Array.from({length:401},(_,i)=>node(80,i===400?'fixed':'static'));").isEmpty)
    }

    @MainActor @Test func visualViewportOffsetsAreApplied() throws {
        #expect(try sample("window.visualViewport={offsetTop:100,height:400};nodes=[node(180),node(600)];") == [80])
    }
}
